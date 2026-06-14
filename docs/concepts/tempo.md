# Tempo
> A distributed-tracing backend that stores the full journey of single requests, looked up cheaply by trace ID from object storage.

**What it is.** Tempo stores **distributed traces**. A *trace* is one request's journey, made of **spans** — one span per unit of work ("handle HTTP request," "query Postgres," "call Redis") — linked by a shared **trace ID** and parent/child relationships. Mental model: a package-tracking history — "arrived at API gateway 12:00:00.000, handed to worker 12:00:00.041, DB query 12:00:00.044–12:00:00.230 (← your 186ms)." Tempo's design bet, like Loki's, is "don't index everything": you look traces up by trace ID and use metrics/logs to *find* that ID.

**How it works.** Apps emit spans using **OpenTelemetry (OTel)**, the vendor-neutral CNCF telemetry standard, over **OTLP** (gRPC port 4317 / HTTP 4318). Spans flow to a collector (Alloy here), which forwards them to Tempo's OTLP receiver; trace blocks land in object storage. Tempo's **metrics-generator** can *derive metrics from traces* — RED metrics (Rate/Errors/Duration) per service and a **service graph** — and remote-write them back into Prometheus, which powers Grafana's automatic service map. Because tracing every request is costly, production usually samples (head vs. tail sampling).

**In this cluster.**
- `apps/observability/tempo.yaml` (chart `1.24.4`, monolithic single replica): trace storage is the MinIO bucket `tempo-traces`; the metrics-generator remote-writes service-graph and span-metrics to `kube-prometheus-stack-prometheus`. A `trace_id` is attached as a Prometheus exemplar *and* written into JSON log lines, enabling metric→trace→log pivots in Grafana.
- `export KUBECONFIG=$PWD/terraform/.kubeconfig && kubectl port-forward -n monitoring svc/tempo 3200:3200 &` then `curl -s 'http://localhost:3200/api/search/tags' | jq .` — lists span attributes like `service.name`.

**See also:** [[grafana]] · [[alloy]] · [[loki]] · [[prometheus]] · [[minio]] · [[observability-pillars]] &nbsp; **Deep dive:** [[06-observability]]
