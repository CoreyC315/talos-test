package main

import (
	"log/slog"
	"net/http"
	"strconv"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"
	"go.opentelemetry.io/otel/trace"
)

var (
	httpRequestsTotal = promauto.NewCounterVec(prometheus.CounterOpts{
		Name: "http_requests_total",
		Help: "Total HTTP requests by path, method and status code.",
	}, []string{"path", "method", "status"})

	httpRequestDuration = promauto.NewHistogramVec(prometheus.HistogramOpts{
		Name:    "http_request_duration_seconds",
		Help:    "HTTP request latency in seconds.",
		Buckets: prometheus.DefBuckets,
	}, []string{"path"})

	itemsCreatedTotal = promauto.NewCounter(prometheus.CounterOpts{
		Name: "ks_items_created_total",
		Help: "Total items created via POST /api/items.",
	})

	cacheHitsTotal = promauto.NewCounter(prometheus.CounterOpts{
		Name: "ks_cache_hits_total",
		Help: "Total Redis cache hits for the items list.",
	})

	cacheMissesTotal = promauto.NewCounter(prometheus.CounterOpts{
		Name: "ks_cache_misses_total",
		Help: "Total Redis cache misses for the items list.",
	})

	queueDepth = promauto.NewGauge(prometheus.GaugeOpts{
		Name: "ks_queue_depth",
		Help: "Current depth (LLEN) of the Redis job queue.",
	})
)

type statusRecorder struct {
	http.ResponseWriter
	status int
}

func (s *statusRecorder) WriteHeader(code int) {
	s.status = code
	s.ResponseWriter.WriteHeader(code)
}

// instrument records Prometheus request metrics (attaching trace exemplars to
// the latency histogram when the request span is sampled) and emits one
// structured JSON log line per request including a "trace_id" field, which
// Loki uses for log->trace (Tempo) correlation.
func instrument(logger *slog.Logger, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		rec := &statusRecorder{ResponseWriter: w, status: http.StatusOK}
		next.ServeHTTP(rec, r)

		path := r.URL.Path
		elapsed := time.Since(start).Seconds()
		httpRequestsTotal.WithLabelValues(path, r.Method, strconv.Itoa(rec.status)).Inc()

		spanCtx := trace.SpanContextFromContext(r.Context())
		traceID := ""
		if spanCtx.HasTraceID() {
			traceID = spanCtx.TraceID().String()
		}

		obs := httpRequestDuration.WithLabelValues(path)
		if eo, ok := obs.(prometheus.ExemplarObserver); ok && spanCtx.IsSampled() {
			eo.ObserveWithExemplar(elapsed, prometheus.Labels{"trace_id": traceID})
		} else {
			obs.Observe(elapsed)
		}

		if path == "/healthz" || path == "/readyz" || path == "/metrics" {
			return
		}
		logger.Info("http_request",
			"method", r.Method,
			"path", path,
			"status", rec.status,
			"duration_ms", float64(time.Since(start).Microseconds())/1000.0,
			"remote_addr", r.RemoteAddr,
			"trace_id", traceID,
		)
	})
}
