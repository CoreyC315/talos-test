# prometheus-adapter
> A translator that exposes selected PromQL queries through the custom-metrics API so the HPA can scale on app signals.

**What it is.** [[metrics-server]] only knows CPU and memory, but you often want to scale on a *business* signal — requests per second, queue depth, p95 latency. prometheus-adapter sits in front of [[prometheus]] and exposes chosen [[promql|PromQL]] queries through the standard `custom.metrics.k8s.io` API, so the [[hpa|HPA]] reads them exactly like it reads CPU. Analogy: a universal-remote dongle that makes Prometheus speak the Kubernetes "metrics" language the HPA already understands.

**How it works.** Like metrics-server, it registers as an **APIService** (`v1beta1.custom.metrics.k8s.io`) on the [[kube-apiserver]] aggregation layer. A **rules** config maps Prometheus series → Kubernetes metric names (`seriesQuery`, `name.matches/as`), associates a series with pods/namespaces via label `overrides`, and defines the `metricsQuery` PromQL to run. When the HPA asks for the metric, the adapter substitutes the pod/namespace and returns the number.

**In this cluster.**
- `apps/observability/prometheus-adapter.yaml` (Helm `5.3.0`, sync-wave `4`). The one custom rule renames `http_requests_total` → `http_requests_per_second` via `metricsQuery: 'sum(rate(<<.Series>>{...}[2m])) by (<<.GroupBy>>)'`, feeding the `ks-api` [[hpa|HPA]]. The counter comes from the ServiceMonitors in `workloads/kubeshowcase/servicemonitors.yaml`.
- Ops note: it was **OOMKilled at 512Mi** when full observability returned (2-day retention = more series to load at startup); the limit was raised to `1Gi`. See [[OPERATIONS]].
- Live: `kubectl get --raw "/apis/custom.metrics.k8s.io/v1beta1/namespaces/kubeshowcase/pods/*/http_requests_per_second" | jq`

**See also:** [[hpa]] · [[metrics-server]] · [[prometheus]] · [[promql]] · [[keda]] · [[observability-pillars]] &nbsp; **Deep dive:** [[05-scaling-scheduling]]
