// Command ks-worker consumes jobs from a Redis list (BRPOP) and simulates
// CPU-bound work. It exposes Prometheus metrics and a health endpoint on
// PORT (default 9090) and drains gracefully on SIGTERM: the job currently
// being processed is always completed before exit.
package main

import (
	"context"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"syscall"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"
	"github.com/prometheus/client_golang/prometheus/promhttp"
	"github.com/redis/go-redis/v9"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/propagation"
	"go.opentelemetry.io/otel/trace"
)

const defaultServiceName = "ks-worker"

var (
	jobsProcessedTotal = promauto.NewCounter(prometheus.CounterOpts{
		Name: "worker_jobs_processed_total",
		Help: "Total jobs processed by this worker.",
	})
	jobsFailedTotal = promauto.NewCounter(prometheus.CounterOpts{
		Name: "worker_jobs_failed_total",
		Help: "Total jobs that failed to parse or process.",
	})
	workerBusy = promauto.NewGauge(prometheus.GaugeOpts{
		Name: "worker_busy",
		Help: "1 while the worker is processing a job, 0 when idle.",
	})
	jobDuration = promauto.NewHistogram(prometheus.HistogramOpts{
		Name:    "worker_job_duration_seconds",
		Help:    "Time spent processing each job.",
		Buckets: prometheus.DefBuckets,
	})
)

type job struct {
	ItemID      int64  `json:"item_id"`
	Name        string `json:"name"`
	Traceparent string `json:"traceparent,omitempty"`
}

func main() {
	logger := slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: slog.LevelInfo}))
	slog.SetDefault(logger)
	if err := run(logger); err != nil {
		logger.Error("fatal error", "error", err)
		os.Exit(1)
	}
}

func run(logger *slog.Logger) error {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	shutdownTracing, err := setupTracing(ctx, defaultServiceName)
	if err != nil {
		return fmt.Errorf("setup tracing: %w", err)
	}

	redisAddr := os.Getenv("REDIS_ADDR")
	if redisAddr == "" {
		redisAddr = "localhost:6379"
	}
	rdb := redis.NewClient(&redis.Options{Addr: redisAddr})
	defer rdb.Close()

	queue := os.Getenv("REDIS_QUEUE")
	if queue == "" {
		queue = "jobs"
	}

	workMS := 500
	if v := os.Getenv("WORK_MS"); v != "" {
		if parsed, err := strconv.Atoi(v); err == nil && parsed > 0 {
			workMS = parsed
		}
	}

	// Metrics / health server.
	port := os.Getenv("PORT")
	if port == "" {
		port = "9090"
	}
	mux := http.NewServeMux()
	mux.Handle("GET /metrics", promhttp.HandlerFor(
		prometheus.DefaultGatherer,
		promhttp.HandlerOpts{EnableOpenMetrics: true},
	))
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("ok"))
	})
	srv := &http.Server{
		Addr:              ":" + port,
		Handler:           mux,
		ReadHeaderTimeout: 10 * time.Second,
	}
	go func() {
		logger.Info("ks-worker metrics listening", "addr", srv.Addr, "queue", queue, "work_ms", workMS)
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			logger.Error("metrics server error", "error", err)
		}
	}()

	tracer := otel.Tracer(defaultServiceName)
	consume(ctx, logger, tracer, rdb, queue, workMS)

	// SIGTERM received and in-flight job finished: shut everything down.
	shutdownCtx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	if err := srv.Shutdown(shutdownCtx); err != nil {
		logger.Error("metrics server shutdown error", "error", err)
	}
	if err := shutdownTracing(shutdownCtx); err != nil {
		logger.Error("tracer shutdown error", "error", err)
	}
	logger.Info("worker drained, shutdown complete")
	return nil
}

// consume runs the BRPOP loop until ctx is cancelled. Jobs are processed with
// a context detached from ctx so an in-flight job survives SIGTERM.
func consume(ctx context.Context, logger *slog.Logger, tracer trace.Tracer, rdb *redis.Client, queue string, workMS int) {
	logger.Info("consuming jobs", "queue", queue)
	for {
		if ctx.Err() != nil {
			return
		}
		res, err := rdb.BRPop(ctx, 5*time.Second, queue).Result()
		if err != nil {
			if errors.Is(err, redis.Nil) {
				continue // timeout, queue empty
			}
			if ctx.Err() != nil {
				return // shutting down
			}
			logger.Error("brpop failed", "error", err.Error())
			select {
			case <-ctx.Done():
				return
			case <-time.After(2 * time.Second):
			}
			continue
		}
		// res is [key, value]
		if len(res) != 2 {
			continue
		}
		processJob(logger, tracer, res[1], workMS)
	}
}

func processJob(logger *slog.Logger, tracer trace.Tracer, payload string, workMS int) {
	workerBusy.Set(1)
	defer workerBusy.Set(0)
	start := time.Now()

	var j job
	if err := json.Unmarshal([]byte(payload), &j); err != nil {
		jobsFailedTotal.Inc()
		logger.Error("invalid job payload", "error", err.Error(), "payload", payload)
		return
	}

	// Join the producer's trace if a traceparent was propagated in the job.
	jobCtx := context.Background()
	if j.Traceparent != "" {
		carrier := propagation.MapCarrier{"traceparent": j.Traceparent}
		jobCtx = otel.GetTextMapPropagator().Extract(jobCtx, carrier)
	}
	ctx, span := tracer.Start(jobCtx, "process_job",
		trace.WithSpanKind(trace.SpanKindConsumer),
		trace.WithAttributes(
			attribute.Int64("job.item_id", j.ItemID),
			attribute.String("job.name", j.Name),
			attribute.Int("job.work_ms", workMS),
		),
	)
	defer span.End()
	_ = ctx

	// Simulate CPU-bound work: hash in a tight loop for ~workMS.
	deadline := start.Add(time.Duration(workMS) * time.Millisecond)
	digest := sha256.Sum256([]byte(j.Name))
	hashes := 0
	for time.Now().Before(deadline) {
		for i := 0; i < 1000; i++ {
			digest = sha256.Sum256(digest[:])
		}
		hashes += 1000
	}
	span.SetAttributes(attribute.Int("job.hashes", hashes))

	elapsed := time.Since(start)
	jobsProcessedTotal.Inc()
	jobDuration.Observe(elapsed.Seconds())

	traceID := ""
	if sc := span.SpanContext(); sc.HasTraceID() {
		traceID = sc.TraceID().String()
	}
	logger.Info("job_processed",
		"item_id", j.ItemID,
		"name", j.Name,
		"duration_ms", float64(elapsed.Microseconds())/1000.0,
		"hashes", hashes,
		"trace_id", traceID,
	)
}
