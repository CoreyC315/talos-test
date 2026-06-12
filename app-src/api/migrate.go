package main

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"os"
	"time"

	"github.com/jackc/pgx/v5"
)

const migrateTimeout = 60 * time.Second

var migrations = []string{
	`CREATE TABLE IF NOT EXISTS items (
		id BIGSERIAL PRIMARY KEY,
		name TEXT NOT NULL,
		created_at TIMESTAMPTZ DEFAULT now()
	)`,
	`CREATE INDEX IF NOT EXISTS items_created_at_idx ON items (created_at DESC)`,
}

// runMigrate connects to PostgreSQL (retrying for up to 60s, so it can be used
// as an initContainer that races the database becoming ready) and applies the
// idempotent schema migrations.
func runMigrate(logger *slog.Logger) error {
	dsn := os.Getenv("DATABASE_URL")
	if dsn == "" {
		return errors.New("DATABASE_URL is required")
	}

	ctx, cancel := context.WithTimeout(context.Background(), migrateTimeout)
	defer cancel()

	var conn *pgx.Conn
	var err error
	for attempt := 1; ; attempt++ {
		conn, err = pgx.Connect(ctx, dsn)
		if err == nil {
			break
		}
		logger.Warn("postgres not ready, retrying", "attempt", attempt, "error", err.Error())
		select {
		case <-ctx.Done():
			return fmt.Errorf("timed out waiting for postgres: %w", err)
		case <-time.After(2 * time.Second):
		}
	}
	defer conn.Close(context.Background())

	for i, stmt := range migrations {
		if _, err := conn.Exec(ctx, stmt); err != nil {
			return fmt.Errorf("migration %d failed: %w", i+1, err)
		}
		logger.Info("applied migration", "index", i+1)
	}
	return nil
}
