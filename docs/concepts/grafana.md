# Grafana
> The single visualization UI that queries metrics, logs, and traces from many backends and renders them as dashboards — one pane of glass.

**What it is.** Grafana is the visualization and exploration UI for observability. It does *not* store data; it *queries datasources* (Prometheus, Loki, Tempo, and ~100 others) and renders dashboards, runs ad-hoc queries in **Explore**, and can send alerts. Mental model: a universal TV remote — the shows (data) live elsewhere, Grafana is the screen and the buttons that let you flip between them.

**How it works.** **Datasources** are connections to backends; this stack wires up Prometheus (default), Loki, and Tempo. **Dashboards as code:** dashboards are stored as JSON inside ConfigMaps labeled `grafana_dashboard`, which a **sidecar** container auto-imports — no clicking around and losing your work. The real payoff is **correlation glue**: `exemplarTraceIdDestinations` links a latency spike straight to its **trace** in Tempo, Loki `derivedFields` turn a `trace_id` in a log line into a clickable Tempo link, and `tracesToLogsV2` jumps from a trace back to its logs. Click the slow request → see its trace → see its logs, all from one screen.

**In this cluster.**
- Datasources and correlation config are in `apps/observability/kube-prometheus-stack.yaml`; dashboards live in `observability/dashboards/*.yaml`; the HTTPRoute is `observability/manifests/httproute-grafana.yaml`. Reach it at `https://grafana.192.168.1.27.nip.io` (user `admin`, password via `sops -d observability/manifests/grafana-admin.sops.yaml`).
- `export KUBECONFIG=$PWD/terraform/.kubeconfig && kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80` then open `http://localhost:3000` → Connections → Datasources should list Prometheus, Loki, Tempo.

**See also:** [[prometheus]] · [[loki]] · [[tempo]] · [[promql]] · [[gateway-api]] · [[sops]] &nbsp; **Deep dive:** [[06-observability]]
