# Prometheus
> A time-series database that scrapes, stores, and alerts on numeric metrics — the de facto standard for Kubernetes monitoring.

**What it is.** Prometheus is a **time-series database (TSDB)**, a metrics scraper, and an alerting engine in one binary. A *time series* is a named stream of numbers over time with labels, e.g. `http_requests_total{path="/api/items", status="200"}` sampled every 15s. Mental model: a spreadsheet where every row is `(metric name, labels, timestamp, value)`, optimized so "per-second rate of this metric over the last hour, grouped by path" is fast. It's a graduated CNCF project — the second ever to graduate, after Kubernetes itself.

**How it works.** Prometheus **pulls** (scrapes): on an interval it makes an HTTP GET to each target's `/metrics` endpoint and appends a sample per series — your app just exposes `/metrics`, it doesn't need to know Prometheus exists. The **Prometheus Operator** removes hand-maintained target lists: it watches Kubernetes for **ServiceMonitor**/**PodMonitor** custom resources and rewrites the scrape config automatically. Metric types are *Counter* (only goes up), *Gauge* (up/down), and *Histogram* (bucketed, for percentiles). It continuously evaluates **alerting rules** (PromQL that fires when true for a duration) and hands firing alerts to **Alertmanager**, which dedupes, groups, silences, and routes them to receivers.

**In this cluster.**
- Chart `kube-prometheus-stack` `86.2.2` with all tuning in `apps/observability/kube-prometheus-stack.yaml`: `retention: 2d`, a 20Gi Longhorn TSDB PVC, and `serviceMonitorSelectorNilUsesHelmValues: false` (scrape *every* ServiceMonitor cluster-wide). Alertmanager routes critical/warning alerts to an `ntfy.sh` webhook.
- `export KUBECONFIG=$PWD/terraform/.kubeconfig && kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090` then open `http://localhost:9090/targets` — every target should be `UP`.

**See also:** [[promql]] · [[node-exporter]] · [[grafana]] · [[observability-pillars]] · [[prometheus-adapter]] · [[longhorn]] &nbsp; **Deep dive:** [[06-observability]]
