# The Three Pillars
> The three kinds of signal — metrics, logs, traces — that together let you see what a running system is doing, so a 2am outage is a 5-minute fix instead of a 5-hour one.

**What it is.** "Observability" is the discipline of instrumenting, collecting, storing, and querying signal from a system. It's classically split into three **pillars**: **metrics** (cheap numeric time series like "CPU 73%"), **logs** (timestamped text events like "connection refused"), and **traces** (the path of a *single* request as it hops across services, with timing per hop). Metrics tell you *that* something is wrong, logs and traces tell you *why*.

**How it works.** Each pillar trades off cost vs. detail: metrics are tiny and great for dashboards/alerts but can't explain root cause; logs are rich but expensive to store and slow to search; traces pinpoint *which* service in a chain is slow. The dominant open-source toolkit is the **LGTM stack** from Grafana Labs — **L**oki (logs), **G**rafana (UI), **T**empo (traces), **M**imir/Prometheus (metrics) — with **Alloy** as the collector. A shared **trace ID**, attached to metric exemplars, log lines, and spans, is the join key that lets you pivot metric → trace → log.

**In this cluster.**
- The whole stack lives in the `monitoring` namespace, deployed by Argo CD at sync-wave 4 from `apps/observability/`.
- `export KUBECONFIG=$PWD/terraform/.kubeconfig && kubectl get pods -n monitoring` — see Prometheus, Grafana, Loki, Tempo, Alloy, node-exporter all `Running`.

**See also:** [[prometheus]] · [[grafana]] · [[loki]] · [[tempo]] · [[alloy]] · [[node-exporter]] &nbsp; **Deep dive:** [[06-observability]]
