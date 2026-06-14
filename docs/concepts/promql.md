# PromQL
> The query language for Prometheus — turns raw time series into rates, percentiles, and aggregates for dashboards and alerts.

**What it is.** PromQL (Prometheus Query Language) is how you ask Prometheus questions about its stored metrics. You select series by metric name and label matchers — `http_requests_total{namespace="kubeshowcase"}` — then transform and aggregate them. Think of it as SQL-for-time-series: instead of rows in a table, you operate on streams of `(timestamp, value)` pairs grouped by label set.

**How it works.** The single most important idiom is `rate(counter[5m])`, which converts a monotonically-increasing counter into a per-second rate averaged over a 5-minute window — you almost never graph a raw counter, you graph its `rate()`. Aggregation operators like `sum by (path) (...)` collapse series across labels. Percentiles come from histograms: `histogram_quantile(0.95, sum by (le) (rate(http_request_duration_seconds_bucket[5m])))` computes p95 latency. Loki's **LogQL** and the alerting rules deliberately reuse this same syntax.

**In this cluster.**
- PromQL powers the p95 panel in `observability/dashboards/kubeshowcase-app.yaml` and the alerting expressions in `observability/manifests/prometheusrules.yaml`.
- `export KUBECONFIG=$PWD/terraform/.kubeconfig && kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090 &` then `curl -s 'http://localhost:9090/api/v1/query?query=up' | jq '.data.result | length'` — count of currently-up scrape targets.

**See also:** [[prometheus]] · [[grafana]] · [[loki]] · [[observability-pillars]] · [[prometheus-adapter]] &nbsp; **Deep dive:** [[06-observability]]
