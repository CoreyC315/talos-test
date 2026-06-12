package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promhttp"
	"github.com/redis/go-redis/v9"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/codes"
	"go.opentelemetry.io/otel/propagation"
	"go.opentelemetry.io/otel/trace"
)

const (
	itemsCacheKey = "ks:items:v1"
	itemsCacheTTL = 10 * time.Second
	maxLoadMS     = 5000
)

type app struct {
	db       *pgxpool.Pool
	rdb      *redis.Client
	queue    string
	version  string
	hostname string
	started  time.Time
	logger   *slog.Logger
	tracer   trace.Tracer
}

type item struct {
	ID        int64     `json:"id"`
	Name      string    `json:"name"`
	CreatedAt time.Time `json:"created_at"`
}

func (a *app) routes() *http.ServeMux {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", a.handleHealthz)
	mux.HandleFunc("GET /readyz", a.handleReadyz)
	mux.HandleFunc("GET /api/items", a.handleListItems)
	mux.HandleFunc("POST /api/items", a.handleCreateItem)
	mux.HandleFunc("GET /api/stats", a.handleStats)
	mux.HandleFunc("POST /api/load", a.handleLoad)
	mux.Handle("GET /metrics", promhttp.HandlerFor(
		prometheus.DefaultGatherer,
		promhttp.HandlerOpts{EnableOpenMetrics: true}, // OpenMetrics enables exemplar exposition
	))
	return mux
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func writeError(w http.ResponseWriter, status int, msg string) {
	writeJSON(w, status, map[string]string{"error": msg})
}

func (a *app) handleHealthz(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Content-Type", "text/plain")
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write([]byte("ok"))
}

func (a *app) handleReadyz(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	if err := a.db.Ping(ctx); err != nil {
		writeError(w, http.StatusServiceUnavailable, "postgres unavailable: "+err.Error())
		return
	}
	if err := a.rdb.Ping(ctx).Err(); err != nil {
		writeError(w, http.StatusServiceUnavailable, "redis unavailable: "+err.Error())
		return
	}
	w.Header().Set("Content-Type", "text/plain")
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write([]byte("ready"))
}

func (a *app) handleListItems(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()

	// Try the Redis cache first.
	cacheCtx, cacheSpan := a.tracer.Start(ctx, "redis.get_items_cache")
	cached, err := a.rdb.Get(cacheCtx, itemsCacheKey).Bytes()
	cacheSpan.End()
	if err == nil {
		cacheHitsTotal.Inc()
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("X-Cache", "hit")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write(cached)
		return
	}
	if !errors.Is(err, redis.Nil) {
		a.logger.Warn("items cache read failed", "error", err.Error())
	}
	cacheMissesTotal.Inc()

	dbCtx, dbSpan := a.tracer.Start(ctx, "db.select_items",
		trace.WithAttributes(attribute.Int("db.limit", 50)))
	rows, err := a.db.Query(dbCtx, `SELECT id, name, created_at FROM items ORDER BY id DESC LIMIT 50`)
	if err != nil {
		dbSpan.RecordError(err)
		dbSpan.SetStatus(codes.Error, "query failed")
		dbSpan.End()
		writeError(w, http.StatusInternalServerError, "database query failed")
		return
	}
	items := make([]item, 0, 50)
	for rows.Next() {
		var it item
		if err := rows.Scan(&it.ID, &it.Name, &it.CreatedAt); err != nil {
			rows.Close()
			dbSpan.RecordError(err)
			dbSpan.SetStatus(codes.Error, "scan failed")
			dbSpan.End()
			writeError(w, http.StatusInternalServerError, "database scan failed")
			return
		}
		items = append(items, it)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		dbSpan.RecordError(err)
		dbSpan.SetStatus(codes.Error, "rows iteration failed")
		dbSpan.End()
		writeError(w, http.StatusInternalServerError, "database read failed")
		return
	}
	dbSpan.SetAttributes(attribute.Int("db.rows", len(items)))
	dbSpan.End()

	payload, err := json.Marshal(map[string]any{"items": items, "count": len(items)})
	if err != nil {
		writeError(w, http.StatusInternalServerError, "encoding failed")
		return
	}

	setCtx, setSpan := a.tracer.Start(ctx, "redis.set_items_cache")
	if err := a.rdb.Set(setCtx, itemsCacheKey, payload, itemsCacheTTL).Err(); err != nil {
		setSpan.RecordError(err)
		a.logger.Warn("items cache write failed", "error", err.Error())
	}
	setSpan.End()

	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("X-Cache", "miss")
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(payload)
}

func (a *app) handleCreateItem(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()

	var req struct {
		Name string `json:"name"`
	}
	r.Body = http.MaxBytesReader(w, r.Body, 1<<20)
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid JSON body")
		return
	}
	req.Name = strings.TrimSpace(req.Name)
	if req.Name == "" {
		writeError(w, http.StatusBadRequest, "name is required")
		return
	}
	if len(req.Name) > 255 {
		writeError(w, http.StatusBadRequest, "name too long (max 255)")
		return
	}

	insCtx, insSpan := a.tracer.Start(ctx, "db.insert_item")
	var created item
	err := a.db.QueryRow(insCtx,
		`INSERT INTO items (name) VALUES ($1) RETURNING id, name, created_at`,
		req.Name,
	).Scan(&created.ID, &created.Name, &created.CreatedAt)
	if err != nil {
		insSpan.RecordError(err)
		insSpan.SetStatus(codes.Error, "insert failed")
		insSpan.End()
		writeError(w, http.StatusInternalServerError, "database insert failed")
		return
	}
	insSpan.SetAttributes(attribute.Int64("item.id", created.ID))
	insSpan.End()
	itemsCreatedTotal.Inc()

	// Invalidate the items cache.
	delCtx, delSpan := a.tracer.Start(ctx, "redis.invalidate_items_cache")
	if err := a.rdb.Del(delCtx, itemsCacheKey).Err(); err != nil {
		delSpan.RecordError(err)
		a.logger.Warn("cache invalidation failed", "error", err.Error())
	}
	delSpan.End()

	// Enqueue a background job, propagating the trace context so the worker
	// can join this trace.
	job := map[string]any{"item_id": created.ID, "name": created.Name}
	carrier := propagation.MapCarrier{}
	otel.GetTextMapPropagator().Inject(ctx, carrier)
	if tp := carrier.Get("traceparent"); tp != "" {
		job["traceparent"] = tp
	}
	jobPayload, _ := json.Marshal(job)

	pushCtx, pushSpan := a.tracer.Start(ctx, "redis.lpush_job",
		trace.WithSpanKind(trace.SpanKindProducer),
		trace.WithAttributes(attribute.String("messaging.destination.name", a.queue)))
	if err := a.rdb.LPush(pushCtx, a.queue, jobPayload).Err(); err != nil {
		pushSpan.RecordError(err)
		pushSpan.SetStatus(codes.Error, "lpush failed")
		a.logger.Error("failed to enqueue job", "error", err.Error(), "item_id", created.ID)
	}
	pushSpan.End()

	writeJSON(w, http.StatusCreated, created)
}

func (a *app) handleStats(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()

	countCtx, countSpan := a.tracer.Start(ctx, "db.count_items")
	var count int64
	if err := a.db.QueryRow(countCtx, `SELECT count(*) FROM items`).Scan(&count); err != nil {
		countSpan.RecordError(err)
		countSpan.SetStatus(codes.Error, "count failed")
		countSpan.End()
		writeError(w, http.StatusInternalServerError, "database count failed")
		return
	}
	countSpan.End()

	llenCtx, llenSpan := a.tracer.Start(ctx, "redis.llen_queue")
	depth, err := a.rdb.LLen(llenCtx, a.queue).Result()
	if err != nil {
		llenSpan.RecordError(err)
		llenSpan.End()
		writeError(w, http.StatusInternalServerError, "queue depth check failed")
		return
	}
	llenSpan.End()
	queueDepth.Set(float64(depth))

	writeJSON(w, http.StatusOK, map[string]any{
		"item_count":     count,
		"queue_depth":    depth,
		"pod":            a.hostname,
		"version":        a.version,
		"uptime_seconds": int64(time.Since(a.started).Seconds()),
	})
}

// handleLoad burns CPU for the requested number of milliseconds by hashing in
// a tight loop. Used to drive HPA demos.
func (a *app) handleLoad(w http.ResponseWriter, r *http.Request) {
	ms := 200
	if v := r.URL.Query().Get("ms"); v != "" {
		parsed, err := strconv.Atoi(v)
		if err != nil {
			writeError(w, http.StatusBadRequest, "ms must be an integer")
			return
		}
		ms = parsed
	}
	if ms < 1 {
		ms = 1
	}
	if ms > maxLoadMS {
		ms = maxLoadMS
	}

	_, span := a.tracer.Start(r.Context(), "cpu.load",
		trace.WithAttributes(attribute.Int("load.ms", ms)))
	defer span.End()

	deadline := time.Now().Add(time.Duration(ms) * time.Millisecond)
	digest := sha256.Sum256([]byte(a.hostname))
	hashes := 0
	for time.Now().Before(deadline) {
		for i := 0; i < 1000; i++ {
			digest = sha256.Sum256(digest[:])
		}
		hashes += 1000
	}
	span.SetAttributes(attribute.Int("load.hashes", hashes))

	writeJSON(w, http.StatusOK, map[string]any{
		"ms":     ms,
		"hashes": hashes,
		"digest": hex.EncodeToString(digest[:8]),
		"pod":    a.hostname,
	})
}

// pollQueueDepth keeps the ks_queue_depth gauge fresh even when nobody is
// calling /api/stats.
func (a *app) pollQueueDepth(ctx context.Context, interval time.Duration) {
	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			depth, err := a.rdb.LLen(ctx, a.queue).Result()
			if err != nil {
				continue
			}
			queueDepth.Set(float64(depth))
		}
	}
}
