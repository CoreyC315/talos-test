// Command ks-api is the KubeShowcase API server.
//
// Subcommands:
//
//	ks-api migrate   run database migrations and exit (used as an initContainer)
//	ks-api           run the HTTP server (default)
package main

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/redis/go-redis/v9"
	"go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp"
	"go.opentelemetry.io/otel"
)

const defaultServiceName = "ks-api"

func main() {
	logger := slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: slog.LevelInfo}))
	slog.SetDefault(logger)

	if len(os.Args) > 1 && os.Args[1] == "migrate" {
		if err := runMigrate(logger); err != nil {
			logger.Error("migration failed", "error", err)
			os.Exit(1)
		}
		logger.Info("migration completed successfully")
		return
	}

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

	dsn := os.Getenv("DATABASE_URL")
	if dsn == "" {
		return errors.New("DATABASE_URL is required")
	}
	db, err := pgxpool.New(ctx, dsn)
	if err != nil {
		return fmt.Errorf("create pg pool: %w", err)
	}
	defer db.Close()

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
	version := os.Getenv("APP_VERSION")
	if version == "" {
		version = "dev"
	}
	hostname, _ := os.Hostname()

	a := &app{
		db:       db,
		rdb:      rdb,
		queue:    queue,
		version:  version,
		hostname: hostname,
		started:  time.Now(),
		logger:   logger,
		tracer:   otel.Tracer(defaultServiceName),
	}

	// Background queue-depth sampler for the ks_queue_depth gauge.
	go a.pollQueueDepth(ctx, 10*time.Second)

	mux := a.routes()
	handler := otelhttp.NewHandler(
		instrument(logger, mux),
		"ks-api",
		otelhttp.WithFilter(func(r *http.Request) bool {
			p := r.URL.Path
			return p != "/metrics" && p != "/healthz" && p != "/readyz"
		}),
	)

	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}
	srv := &http.Server{
		Addr:              ":" + port,
		Handler:           handler,
		ReadHeaderTimeout: 10 * time.Second,
	}

	errCh := make(chan error, 1)
	go func() {
		logger.Info("ks-api listening", "addr", srv.Addr, "version", version, "queue", queue)
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			errCh <- err
		}
	}()

	select {
	case err := <-errCh:
		return fmt.Errorf("http server: %w", err)
	case <-ctx.Done():
		logger.Info("shutdown signal received, draining connections")
	}

	shutdownCtx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	if err := srv.Shutdown(shutdownCtx); err != nil {
		logger.Error("http shutdown error", "error", err)
	}
	if err := shutdownTracing(shutdownCtx); err != nil {
		logger.Error("tracer shutdown error", "error", err)
	}
	logger.Info("shutdown complete")
	return nil
}
