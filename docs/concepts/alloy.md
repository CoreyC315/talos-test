# Grafana Alloy
> The single agent (a DaemonSet) that discovers, relabels, and ships logs to Loki and traces to Tempo — the collector layer, distinct from the backends.

**What it is.** Alloy is Grafana's telemetry collector/pipeline agent — the successor to "Grafana Agent" and a distribution of the **OpenTelemetry Collector**. One agent that can scrape, receive, transform, and ship metrics, logs, and traces. Mental model: the mailroom of the observability building — it picks up packages (telemetry) from every source, relabels and sorts them, and routes each to the right warehouse (Loki for logs, Tempo for traces). In this cluster Alloy handles **logs and traces** (Prometheus does its own metric scraping).

**How it works.** Alloy config is a pipeline of **components** wired by references — each has inputs and a `forward_to`/`output`, so the config reads like a dataflow graph. Here the pipeline: `discovery.kubernetes` finds pods (filtered to *this* node via `spec.nodeName=$HOSTNAME` so a DaemonSet doesn't ship every log three times) → `discovery.relabel` attaches `namespace`/`pod`/`container` labels → `loki.source.kubernetes` → `loki.write` pushes to `loki-gateway`. In parallel, `otelcol.receiver.otlp` (ports 4317/4318) → `otelcol.processor.batch` → `otelcol.exporter.otlp` ships traces to Tempo. It reads logs via the **Kubernetes API**, not hostPath — a Talos-friendly choice since the node filesystem is locked down.

**In this cluster.**
- `apps/observability/alloy.yaml` (chart `1.10.0`, `controller.type: daemonset`); the full River pipeline is inline. Apps send OTLP traces to the `alloy` Service on 4317/4318.
- `export KUBECONFIG=$PWD/terraform/.kubeconfig && kubectl port-forward -n monitoring ds/alloy 12345:12345` then open `http://localhost:12345` — Alloy's debug UI shows each component, its health, and live throughput.

**See also:** [[loki]] · [[tempo]] · [[grafana]] · [[node-exporter]] · [[observability-pillars]] &nbsp; **Deep dive:** [[06-observability]]
