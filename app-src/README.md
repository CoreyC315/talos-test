# KubeShowcase (app-src)

A small but production-grade three-tier demo app used to exercise the platform:
HPA/KEDA scaling, Prometheus metrics with exemplars, OTel tracing, and
Loki-friendly JSON logs with `trace_id` correlation.

## Components

| Component | Path | Description |
|---|---|---|
| **ks-api** | `api/` | Go HTTP API. Postgres-backed items CRUD, Redis cache + job producer, CPU load generator, Prometheus `/metrics`, OTel traces. Also ships a `migrate` subcommand for use as an initContainer. |
| **ks-worker** | `worker/` | Go queue consumer. `BRPOP`s jobs from Redis, simulates CPU work, emits consumer spans (joins the API's trace via `traceparent` in the job payload), metrics on `:9090`. Drains gracefully on SIGTERM. |
| **ks-frontend** | `frontend/` | React + Vite SPA served by unprivileged nginx on `:8080`. Calls the API via same-origin `/api/*` (routed by the Gateway). |

## Environment variables

| Variable | Used by | Default | Purpose |
|---|---|---|---|
| `DATABASE_URL` | api | (required) | Postgres DSN, e.g. `postgres://user:pass@host:5432/db` |
| `REDIS_ADDR` | api, worker | `localhost:6379` | Redis `host:port` |
| `REDIS_QUEUE` | api, worker | `jobs` | Redis list used as the job queue |
| `PORT` | all | api `8080`, worker `9090`, frontend `8080` | HTTP listen port |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | api, worker | SDK default | OTLP gRPC collector, e.g. `http://alloy.monitoring.svc.cluster.local:4317` |
| `OTEL_SERVICE_NAME` | api, worker | `ks-api` / `ks-worker` | Trace service name |
| `APP_VERSION` | api, worker | `dev` | Version reported in `/api/stats` and traces |
| `WORK_MS` | worker | `500` | Simulated CPU time per job (ms) |

## API endpoints (ks-api)

- `GET /healthz` — liveness, always 200
- `GET /readyz` — readiness, pings Postgres + Redis (503 if either is down)
- `GET /api/items` — last 50 items; 10s Redis cache; `X-Cache: hit|miss` header
- `POST /api/items` — body `{"name":"..."}`; inserts, invalidates cache, enqueues a job
- `GET /api/stats` — item count, queue depth, pod hostname, version, uptime
- `POST /api/load?ms=400` — busy-loops SHA-256 for `ms` milliseconds (default 200, cap 5000); HPA load generator
- `GET /metrics` — Prometheus (OpenMetrics, with trace exemplars)

Worker endpoints: `GET /metrics`, `GET /healthz` on `:9090`.

Key metrics: `http_requests_total`, `http_request_duration_seconds`,
`ks_items_created_total`, `ks_cache_hits_total` / `ks_cache_misses_total`,
`ks_queue_depth`, `worker_jobs_processed_total`, `worker_busy`.

## Local development

Prereqs: Postgres + Redis running locally (e.g. `docker run -d -p 5432:5432 -e POSTGRES_PASSWORD=pg postgres:17` and `docker run -d -p 6379:6379 redis:7`).

```sh
# API (Go 1.25)
cd api
export DATABASE_URL=postgres://postgres:pg@localhost:5432/postgres
go mod tidy
go run . migrate     # create schema
go run .             # serve on :8080

# Worker
cd worker
go mod tidy
go run .             # metrics on :9090

# Frontend (Node 22+); dev server proxies /api -> localhost:8080
cd frontend
npm install
npm run dev          # http://localhost:5173
```

Container images (each directory has a multi-stage Dockerfile; `go mod tidy`
runs at build time, so no `go.sum` is committed):

```sh
docker build -t ks-api ./api
docker build -t ks-worker ./worker
docker build -t ks-frontend ./frontend
```
