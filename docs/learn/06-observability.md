# Module 6: Observability — Metrics, Logs & Traces (the LGTM Stack)

> When something breaks at 2am, the difference between a 5-minute fix and a 5-hour outage is whether
> you can *see* what your system is doing. "Observability" is the discipline of instrumenting,
> collecting, storing, and querying that signal. Almost every platform/SRE/DevOps job description
> lists Prometheus and Grafana by name; many add Loki, Tempo, or OpenTelemetry. After this module
> you'll be able to read a PromQL query, find why a pod is slow, follow one HTTP request from a
> metric spike to its logs to its distributed trace, and explain how every piece of *this* cluster's
> monitoring stack fits together — because you built it.

## The big picture

Observability is traditionally described as **three pillars**:

- **Metrics** — cheap numeric time series ("CPU is 73%", "412 requests/sec"). Great for dashboards
  and alerts, bad at explaining *why*.
- **Logs** — timestamped text events ("user 5 logged in", "connection refused"). Rich detail, but
  expensive to store and slow to search at scale.
- **Traces** — the path of a *single* request as it hops across services, with timing for each hop.
  This is how you find "the checkout is slow because the inventory service is slow because its
  database query is slow."

The dominant open-source toolkit for all three is the **LGTM stack** from Grafana Labs — **L**oki
(logs), **G**rafana (the UI), **T**empo (traces), **M**imir/Prometheus (metrics) — with **Alloy** as
the agent that collects everything. This cluster runs exactly that, plus the upstream CNCF
**Prometheus** project (via the `kube-prometheus-stack` bundle) instead of Mimir.

Here is how the pieces relate in this cluster. Everything lives in the `monitoring` namespace and is
deployed by Argo CD (see Module 4) from `apps/observability/`:

```
   your app (kubeshowcase api/worker)                Talos nodes + every pod
   |  /metrics      |  stdout logs    | OTLP traces        |  /proc, cgroups, k8s API
   v                v                 v                    v
 Prometheus  <--scrapes        Alloy (DaemonSet)     node-exporter + kube-state-metrics
   |  (pulls metrics)         (pushes logs/traces)        (expose more /metrics)
   |                          /            \                     |
   |  TSDB on Longhorn   Loki (logs)    Tempo (traces)          | (also scraped by Prometheus)
   |       |                |  S3=MinIO     |  S3=MinIO          |
   |       |                |               |                   |
   +-------+----------------+---------------+-------------------+
                            |
                       Grafana  <-- one UI, queries all three datasources
                            ^
                       you, at grafana.192.168.1.27.nip.io
                            |
   Prometheus --rules--> Alertmanager --webhook--> ntfy (your phone)
```

**Pull vs push** is the key architectural split to internalize: Prometheus *pulls* (scrapes) metrics
from targets on a schedule; Loki and Tempo are *pushed* to by Alloy. Both models are everywhere in
the industry, and "why does Prometheus pull instead of push?" is a genuine interview question.

## Tools in this module

### Prometheus — the metrics database that scrapes, stores, and alerts

- **What it is / mental model:** Prometheus is a **time-series database (TSDB)** plus a scraper plus
  an alerting engine, all in one binary. A *time series* is a named stream of numbers over time, like
  `http_requests_total{path="/api/items", status="200"}` sampled every 15 seconds. Mental model: a
  spreadsheet where every row is `(metric name, labels, timestamp, value)`, optimized so that
  "give me the per-second rate of this metric over the last hour, grouped by path" is fast.
  Prometheus is the *de facto* standard — it's a graduated CNCF project and the second project ever
  to graduate after Kubernetes itself.
- **How it works:**
  - **The scrape model (pull):** Prometheus has a list of *targets* (IP:port/path). On an interval
    it makes an HTTP GET to each target's `/metrics` endpoint, which returns plain text like
    `http_requests_total{path="/api/items"} 4127`. Prometheus parses that and appends a sample to
    each series. Your app doesn't need to know Prometheus exists — it just exposes `/metrics`. (See
    `app-src/api/metrics.go` for the Go side: `promauto.NewCounterVec(...)` registers
    `http_requests_total`.)
  - **Metric types:** *Counter* (only goes up — total requests), *Gauge* (up/down — queue depth,
    memory), *Histogram* (bucketed observations — request latency, lets you compute percentiles),
    *Summary* (similar, client-side quantiles). Your API uses all three:
    `httpRequestsTotal` (counter), `queueDepth` (gauge), `httpRequestDuration` (histogram).
  - **PromQL** is the query language. The single most important idiom: `rate(counter[5m])` turns a
    monotonically-increasing counter into a per-second rate averaged over a 5-minute window. You
    almost never graph a raw counter; you graph its `rate()`. Percentiles come from
    `histogram_quantile(0.95, sum by (le) (rate(http_request_duration_seconds_bucket[5m])))` — this
    exact query powers the "p95" panel in `observability/dashboards/kubeshowcase-app.yaml`.
  - **Service discovery via the Operator:** Hand-maintaining a target list is miserable. The
    **Prometheus Operator** (bundled here) watches Kubernetes for two custom resources —
    **ServiceMonitor** and **PodMonitor** — and rewrites Prometheus's scrape config automatically. A
    ServiceMonitor says "scrape every pod behind any Service matching these labels, on port `http`,
    path `/metrics`." See `workloads/kubeshowcase/servicemonitors.yaml`: the `ks-api` ServiceMonitor
    selects `app: ks-api` and scrapes port `http` `/metrics` every 15s.
  - **Alertmanager** is a separate component. Prometheus continuously evaluates **alerting rules**
    (PromQL expressions that, when true for a duration, *fire*) and hands firing alerts to
    Alertmanager, which **deduplicates, groups, silences, and routes** them to receivers
    (email/Slack/PagerDuty/webhook). In this cluster, rules live in
    `observability/manifests/prometheusrules.yaml` (a `PrometheusRule` CR — also discovered by the
    Operator) and Alertmanager routes critical/warning alerts to a webhook at `ntfy.sh` (config in
    `apps/observability/kube-prometheus-stack.yaml` lines 41-63).
- **In THIS cluster:**
  - Chart/version and all tuning: `apps/observability/kube-prometheus-stack.yaml`. Note line 22
    `retention: 2d` (how long samples are kept), lines 26-29 (`...SelectorNilUsesHelmValues: false`
    makes Prometheus scrape **every** ServiceMonitor/PodMonitor cluster-wide, not just labeled
    ones), and lines 30-37 (its TSDB is a 20Gi Longhorn PVC).
  - Live — list every target and its health:
    ```bash
    export KUBECONFIG=$PWD/terraform/.kubeconfig
    kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090
    # then open http://localhost:9090/targets — every row should be state=UP
    ```
  - Live — run a PromQL query from the CLI (no UI needed):
    ```bash
    kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090 &
    curl -s 'http://localhost:9090/api/v1/query?query=up' | jq '.data.result | length'
    # a number > 30: that's how many scrape targets are currently up
    ```
    Look for: the `up` metric is Prometheus's built-in health signal — `1` per healthy target.
- **Job relevance:** This is the highest-yield single tool in the module. Interviewers ask:
  "counter vs gauge vs histogram," "what does `rate()` do and why not graph the raw counter,"
  "how does Prometheus discover targets in Kubernetes" (answer: Operator + ServiceMonitor),
  "pull vs push tradeoffs," "what does Alertmanager do that Prometheus doesn't" (grouping/routing/
  silencing). Maps to **CKA** (cluster monitoring is in the curriculum) and is assumed background
  for almost any SRE role.
- **Learn it:**
  - prometheus.io → "Getting started" and the "Querying" / "Querying basics" section for PromQL.
  - prometheus.io → "Alerting" → "Alertmanager" overview.
  - prometheus-operator.dev → "Design" and the "ServiceMonitor" / "PodMonitor" API docs.
  - Free: "Prometheus: Up & Running" (O'Reilly) is the canonical book if you want depth.

### kube-prometheus-stack — the batteries-included monitoring bundle

- **What it is / mental model:** A single Helm chart from the `prometheus-community` project that
  installs and wires together *everything* you need to monitor a Kubernetes cluster: the Prometheus
  Operator, a Prometheus instance, Alertmanager, Grafana, node-exporter, kube-state-metrics, and a
  big library of pre-built dashboards and alert rules. Mental model: an IKEA "room in a box" — you
  could buy each piece separately and assemble it, but this gives you a coherent, pre-wired set with
  one set of values to tune.
- **How it works:** It's a meta-chart — it pulls in the subordinate charts (grafana,
  kube-state-metrics, prometheus-node-exporter) as dependencies and exposes their values under
  top-level keys (`grafana:`, `kube-state-metrics:`, etc.). It also ships default ServiceMonitors
  for the Kubernetes control plane (apiserver, kubelet, coredns) and a default set of alerting rules.
  You customize via Helm `valuesObject`, which is exactly what this repo does.
- **In THIS cluster:** `apps/observability/kube-prometheus-stack.yaml`, chart version `86.2.2`
  (line 13). Several defaults are deliberately **disabled** because of Talos specifics — and these
  are great talking points:
  - Lines 122-124: `kubeProxy.enabled: false` because this is a **kube-proxy-free Cilium** cluster
    (Module 3) — there's no kube-proxy to scrape.
  - Lines 125-131: scheduler/controller-manager/etcd scraping disabled because **Talos binds those
    metrics endpoints to localhost**, so Prometheus can't reach them over the network.
  - Lines 145-151: the `monitoring` namespace is labeled `pod-security.../enforce: privileged`
    because node-exporter needs hostNetwork/hostPID/hostPath, which the cluster-default `baseline`
    Pod Security Admission level forbids (you'll meet PSA in the security module).
  - Live — see all the components the bundle created:
    ```bash
    export KUBECONFIG=$PWD/terraform/.kubeconfig
    kubectl get pods -n monitoring -l 'release=kube-prometheus-stack'
    ```
    Look for: `operator`, `grafana`, `kube-state-metrics`, a `node-exporter` per node, plus the
    `prometheus-...-0` and `alertmanager-...-0` StatefulSet pods.
- **Job relevance:** Knowing that "kube-prometheus-stack" (and its cousin the raw `kube-prometheus`
  jsonnet project) is the standard way teams deploy monitoring saves you reinventing it on the job.
  Interviewers like "how would you stand up monitoring for a new cluster?" — naming this and the
  Operator pattern is the expected answer.
- **Learn it:**
  - GitHub `prometheus-community/helm-charts` → the `kube-prometheus-stack` chart README (search
    "kube-prometheus-stack values").
  - GitHub `prometheus-operator/kube-prometheus` → "Quickstart" (the upstream jsonnet project this
    chart is based on).

### node-exporter & kube-state-metrics — turning infrastructure into metrics

- **What it is / mental model:** Prometheus only scrapes things that expose `/metrics`. Most things
  don't natively. These two *exporters* fill the gap from opposite directions:
  - **node-exporter** runs on every node (a DaemonSet) and exposes the *machine's* health — CPU,
    memory, disk, filesystem, network — by reading Linux `/proc` and `/sys`. Analogy: the dashboard
    gauges in a car, one per physical engine.
  - **kube-state-metrics (KSM)** runs once and exposes the *Kubernetes API's* state as metrics —
    "how many replicas does this Deployment want vs have," "is this node Ready," "is this pod
    Pending." Analogy: a clipboard tally of every object the cluster *thinks* it has. It reports the
    cluster's *desired/actual state*, not resource usage.
- **How it works:** Both are plain HTTP servers exposing `/metrics`; the bundle ships ServiceMonitors
  so Prometheus scrapes them automatically. node-exporter metrics are prefixed `node_`
  (e.g. `node_memory_MemAvailable_bytes`); KSM metrics are prefixed `kube_`
  (e.g. `kube_node_status_condition`, `kube_pod_container_status_restarts_total`). Your alert rules
  lean on both — `prometheusrules.yaml` line 27 uses `node_memory_*` (node-exporter) and line 19 uses
  `kube_node_status_condition` (KSM).
- **In THIS cluster:** Enabled at `apps/observability/kube-prometheus-stack.yaml` lines 112-121.
  - Live:
    ```bash
    export KUBECONFIG=$PWD/terraform/.kubeconfig
    kubectl get pods -n monitoring -l app.kubernetes.io/name=prometheus-node-exporter -o wide
    ```
    Look for: exactly **one node-exporter pod per node**, each with the node's real host IP
    (e.g. `192.168.1.20`) — that's the DaemonSet pattern using hostNetwork.
- **Job relevance:** "Where does Prometheus get node CPU/memory?" → node-exporter. "How do you alert
  on a Deployment that can't reach its desired replicas?" → kube-state-metrics. Confusing the two (or
  thinking metrics-server and KSM are the same — they're not; metrics-server feeds `kubectl top` and
  the HPA, KSM feeds Prometheus) is a common stumble. CKA-adjacent.
- **Learn it:**
  - github.com/prometheus/node_exporter → README "Enabled by default" collectors list.
  - github.com/kubernetes/kube-state-metrics → "Documentation" → the metrics-per-object reference.

### Grafana — one pane of glass for metrics, logs, and traces

- **What it is / mental model:** The visualization and exploration UI. Grafana doesn't store data; it
  *queries datasources* (Prometheus, Loki, Tempo, and ~100 others) and renders dashboards, runs ad-hoc
  queries in **Explore**, and (optionally) sends alerts. Mental model: a universal TV remote — the
  shows (data) live elsewhere, Grafana is the screen and the buttons that let you flip between them.
- **How it works:**
  - **Datasources** are connections to backends. This stack wires up three (see
    `apps/observability/kube-prometheus-stack.yaml`): Prometheus is the default; Loki (uid `loki`,
    lines 85-96) and Tempo (uid `tempo`, lines 97-111) are added.
  - **Dashboards as code:** instead of clicking around and losing your work, dashboards are stored as
    JSON. The Grafana **sidecar** container (enabled lines 75-79) watches for ConfigMaps labeled
    `grafana_dashboard` and auto-imports them. This repo's dashboards live in
    `observability/dashboards/*.yaml` (each a ConfigMap wrapping a JSON dashboard) — e.g.
    `kubeshowcase-app.yaml`, `cluster-overview.yaml`, `cilium-hubble.yaml`, `longhorn.yaml`.
  - **Correlation glue** is the magic of a unified stack. The config sets up
    `exemplarTraceIdDestinations` (line 82) so a spike on a Prometheus latency graph links straight
    to the *trace* that caused it; `derivedFields` on Loki (lines 92-96) turn a `trace_id` in a log
    line into a clickable link to Tempo; and `tracesToLogsV2` (lines 103-107) jumps from a trace back
    to its logs. This is "click the slow request → see its trace → see its logs," all from one screen.
- **In THIS cluster:** Reach it at `https://grafana.192.168.1.27.nip.io` (login `admin`; password via
  `sops -d observability/manifests/grafana-admin.sops.yaml`). The HTTPRoute is
  `observability/manifests/httproute-grafana.yaml`.
  - Live — confirm Grafana sees all three datasources without the UI:
    ```bash
    export KUBECONFIG=$PWD/terraform/.kubeconfig
    kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80
    # open http://localhost:3000  (or use the nip.io URL via the Gateway)
    ```
    Look for: under Connections → Datasources you should see Prometheus, Loki, and Tempo; under
    Dashboards you should see "KubeShowcase App" and "Cluster Overview".
- **Job relevance:** Universally expected. Interviewers ask "how do you make dashboards reproducible"
  (answer: JSON-as-code + provisioning sidecar, which is exactly this) and "how do you correlate a
  metric anomaly with logs/traces." Being able to *build a panel from a PromQL query* in an interview
  whiteboard is a strong signal.
- **Learn it:**
  - grafana.com/docs → "Grafana fundamentals" tutorial and "Explore" docs.
  - grafana.com/docs → "Provision dashboards" (search "provisioning dashboards") to understand the
    sidecar/ConfigMap pattern.

### Loki — logs that you query like metrics (and store cheaply)

- **What it is / mental model:** Loki is a log database from Grafana Labs. Its slogan is
  "Prometheus, but for logs." The key idea: **don't index the log text, only index a few labels**
  (namespace, pod, container) — store the raw log lines compressed in cheap object storage and brute-
  force-scan them at query time. Mental model: instead of building a giant searchable index of every
  word in every book (expensive, like Elasticsearch), Loki just labels each *shelf* (pod) and reads
  the books on the relevant shelf when you ask. Much cheaper, slightly slower for needle-in-haystack
  full-text search.
- **How it works:**
  - **Labels + streams:** a *stream* is a unique set of labels (e.g.
    `{namespace="kubeshowcase", pod="ks-api-xyz", container="api"}`); each stream is an append-only
    log of lines. You query with **LogQL**, which deliberately mirrors PromQL:
    `{namespace="kubeshowcase"} |= "error"` ("lines from that namespace containing 'error'"), and you
    can even turn logs into metrics: `rate({namespace="kubeshowcase"} |= "error" [5m])`.
  - **Storage:** index + compressed log chunks go to object storage. Here that's **MinIO** (an
    S3-compatible store running in-cluster) — see `apps/observability/loki.yaml` lines 32-43, buckets
    `loki-chunks` / `loki-ruler`, endpoint `minio.minio.svc.cluster.local:9000`.
  - **Deployment modes:** Loki can run as a single binary, "simple scalable" (read/write/backend), or
    fully microservices. This cluster runs **SingleBinary** (line 18) with caches off because the
    nodes are RAM-constrained (~14GB total). Retention is 72h (line 45), enforced by the compactor.
- **In THIS cluster:** `apps/observability/loki.yaml` (chart `7.0.0`). Logs arrive via the
  `loki-gateway` Service (`http://loki-gateway.monitoring.svc.cluster.local`), which is what Alloy
  pushes to.
  - Live — query logs from the CLI:
    ```bash
    export KUBECONFIG=$PWD/terraform/.kubeconfig
    kubectl port-forward -n monitoring svc/loki-gateway 8080:80 &
    curl -s -G 'http://localhost:8080/loki/api/v1/labels' | jq .
    # then query a stream:
    curl -s -G 'http://localhost:8080/loki/api/v1/query_range' \
      --data-urlencode 'query={namespace="kubeshowcase"}' --data-urlencode 'limit=5' | jq '.data.result | length'
    ```
    Look for: the `/labels` call returns `namespace`, `pod`, `container` (the labels Alloy attaches);
    the query returns recent log lines. (Easier path: do this in Grafana → Explore → Loki.)
- **Job relevance:** Loki is increasingly the default OSS logging backend (vs ELK/Elasticsearch).
  Interviewers ask "how does Loki keep storage cheap" (label-only index + object storage) and "Loki
  vs Elasticsearch" (cheap+label-scoped vs full-text-indexed). Knowing LogQL mirrors PromQL is a
  quick win.
- **Learn it:**
  - grafana.com/docs/loki → "Loki overview" and the "LogQL" reference.
  - grafana.com/docs/loki → "Deployment modes" (to understand SingleBinary vs scalable).

### Tempo — distributed tracing at scale

- **What it is / mental model:** Tempo stores **distributed traces**. A *trace* is one request's
  journey; it's made of **spans** (one span per unit of work, e.g. "handle HTTP request," "query
  Postgres," "call Redis"), linked by a shared **trace ID** and parent/child relationships. Mental
  model: a package-tracking history — "arrived at API gateway 12:00:00.000, handed to worker
  12:00:00.041, DB query 12:00:00.044–12:00:00.230 (← here's your 186ms)." Tempo's design bet, like
  Loki's, is "don't index everything" — you look traces up by **trace ID** (cheaply, from object
  storage), and use metrics/logs to *find* the trace ID.
- **How it works:**
  - **Ingest:** apps emit spans using **OpenTelemetry (OTel)** — the vendor-neutral CNCF standard for
    telemetry. Your Go API does this in `app-src/api/tracing.go` (`otlptracegrpc` exporter, OTLP over
    gRPC). Spans go to a collector (Alloy here), which forwards to Tempo's **OTLP** receiver on ports
    4317 (gRPC) / 4318 (HTTP) — see `apps/observability/tempo.yaml` lines 42-48.
  - **Storage:** trace blocks in object storage (MinIO bucket `tempo-traces`, lines 31-41).
  - **Metrics-generator:** Tempo can *derive metrics from traces* — RED metrics (Rate/Errors/
    Duration) per service and a **service graph** — and remote-write them back into Prometheus
    (lines 49-57). That's what powers Grafana's automatic service map.
  - **Sampling:** tracing every request is expensive; production usually samples. This app uses
    `ParentBased(AlwaysSample())` (tracing.go line 43) — sample everything, honoring upstream
    decisions — fine for a demo, but "head vs tail sampling" is a real interview topic.
- **In THIS cluster:** `apps/observability/tempo.yaml` (chart `1.24.4`), monolithic single replica.
  The full correlation loop is live: a request hits `ks-api` → a span is created with a `trace_id` →
  that same `trace_id` is attached as a **Prometheus exemplar** on the latency histogram
  (`app-src/api/metrics.go` lines 77-82) *and* written into the JSON log line
  (metrics.go line 93) → in Grafana you can pivot metric→trace→log by that ID.
  - Live — confirm Tempo is receiving traces:
    ```bash
    export KUBECONFIG=$PWD/terraform/.kubeconfig
    kubectl port-forward -n monitoring svc/tempo 3200:3200 &
    curl -s 'http://localhost:3200/api/search/tags' | jq .
    # generate some traffic first, then in Grafana → Explore → Tempo → Search by service name
    curl -s 'https://app.192.168.1.27.nip.io/api/items' -k >/dev/null   # makes a trace
    ```
    Look for: `/api/search/tags` lists span attributes like `service.name`; after hitting the app you
    can find that trace in Grafana's Tempo explorer.
- **Job relevance:** Tracing is the "senior" pillar — many teams have metrics+logs but weak tracing,
  so demonstrating you understand spans/trace IDs/OpenTelemetry/sampling sets you apart. Expect "what
  is a span," "how do you propagate a trace across services" (context propagation headers — see the
  `propagation.TraceContext` propagator in tracing.go line 47), and "metrics vs traces — when do you
  reach for which."
- **Learn it:**
  - grafana.com/docs/tempo → "Tempo overview" and "Metrics-generator."
  - opentelemetry.io → "Concepts" → "Signals" → "Traces" (the vendor-neutral foundation).

### Grafana Alloy — the single agent that collects logs and traces

- **What it is / mental model:** Alloy is Grafana's **telemetry collector/pipeline** agent (the
  successor to "Grafana Agent," and a distribution of the OpenTelemetry Collector). One agent that
  can scrape, receive, transform, and ship metrics, logs, and traces. Mental model: the mailroom of
  the observability building — it picks up packages (telemetry) from every source, relabels and
  sorts them, and routes each to the right warehouse (Loki for logs, Tempo for traces). In this
  cluster Alloy handles **logs and traces** (Prometheus handles its own metric scraping).
- **How it works:**
  - **River/Alloy config** is a pipeline of **components** wired by references — each component has
    inputs and an `output`/`forward_to`, so config reads like a dataflow graph. The whole pipeline is
    inline in `apps/observability/alloy.yaml` (lines 34-100). Walk it:
    1. `discovery.kubernetes "pods"` — find pods, **filtered to this node** via
       `spec.nodeName=$HOSTNAME` (lines 38-44) so the DaemonSet doesn't ship every log three times.
    2. `discovery.relabel "pods"` — attach `namespace`/`pod`/`container` labels (lines 46-61); these
       become the Loki stream labels.
    3. `loki.source.kubernetes` → `loki.write` — read the pod logs and **push** them to
       `loki-gateway` (lines 63-72).
    4. `otelcol.receiver.otlp` → `otelcol.processor.batch` → `otelcol.exporter.otlp "tempo"` —
       receive OTLP traces from apps on 4317/4318, batch them, export to Tempo (lines 74-100).
  - **DaemonSet:** Alloy runs one pod per node (`controller.type: daemonset`, line 18) so it's local
    to the pods/logs it collects. Notice it reads logs via the **Kubernetes API**, not hostPath
    (comment line 35) — a Talos-friendly choice since the node filesystem is locked down.
- **In THIS cluster:** `apps/observability/alloy.yaml` (chart `1.10.0`). Apps send traces to the
  `alloy` Service on 4317/4318; Alloy forwards to Tempo.
  - Live:
    ```bash
    export KUBECONFIG=$PWD/terraform/.kubeconfig
    kubectl get pods -n monitoring -l app.kubernetes.io/name=alloy -o wide   # one per node
    # Alloy ships its own debug UI:
    kubectl port-forward -n monitoring ds/alloy 12345:12345
    # open http://localhost:12345 → see each component, its health, and live throughput
    ```
    Look for: the Alloy UI graph showing `discovery.kubernetes` → `loki.write` and
    `otelcol.receiver.otlp` → `otelcol.exporter.otlp` all healthy.
- **Job relevance:** "What ships your logs/traces to the backend?" is a real question, and the
  industry is consolidating on OpenTelemetry Collector / Alloy as the answer (replacing
  Promtail/Fluentd/Fluent Bit for many shops). Knowing the *collector* is a distinct layer from the
  *backend* (Loki/Tempo) — and that one agent can fan telemetry out to many backends — is the
  insight to convey.
- **Learn it:**
  - grafana.com/docs/alloy → "Introduction to Grafana Alloy" and "Components" reference.
  - opentelemetry.io → "Collector" → "Architecture" (the upstream concept Alloy implements).

### prometheus-adapter — bonus: metrics that drive autoscaling

- **What it is / mental model:** Not a pillar, but it lives in this folder and ties metrics to
  *action*. The adapter exposes Prometheus queries to Kubernetes as the **custom.metrics.k8s.io** API,
  so a HorizontalPodAutoscaler (HPA) can scale on application metrics like requests-per-second, not
  just CPU. Mental model: a translator that lets the autoscaler "speak Prometheus."
- **How it works:** It registers as an APIService; when the HPA asks "what is `http_requests_per_second`
  for these pods," the adapter runs the configured PromQL against Prometheus and answers. See the rule
  in `apps/observability/prometheus-adapter.yaml` lines 26-36: it maps `http_requests_total` →
  `http_requests_per_second` via `rate(...)`. (You'll meet the HPA itself in the autoscaling module;
  `workloads/kubeshowcase/autoscaling.yaml` consumes this.)
- **In THIS cluster:** `apps/observability/prometheus-adapter.yaml` (chart `5.3.0`).
  - Live:
    ```bash
    export KUBECONFIG=$PWD/terraform/.kubeconfig
    kubectl get apiservices | grep custom.metrics
    kubectl get --raw '/apis/custom.metrics.k8s.io/v1beta1' | jq '.resources[].name' | head
    ```
    Look for: the `custom.metrics.k8s.io` APIService present and `pods/http_requests_per_second`
    among the exposed metrics.
- **Job relevance:** "How do you autoscale on a custom metric like RPS or queue length?" → custom
  metrics adapter (this) or KEDA. CKAD-adjacent (HPA) and a strong platform-eng talking point.
- **Learn it:**
  - github.com/kubernetes-sigs/prometheus-adapter → README "Configuration" walkthrough.
  - kubernetes.io → "Horizontal Pod Autoscaler" → "Scaling on custom metrics."

## Hands-on lab (on YOUR cluster)

Run this first in every terminal:
```bash
export KUBECONFIG=$PWD/terraform/.kubeconfig
```

**1. See the whole stack and the pull/push split.**
```bash
kubectl get pods -n monitoring
```
Success: Prometheus, Alertmanager, Grafana, kube-state-metrics, one node-exporter and one Alloy per
node, Loki, Tempo all `Running`. Then port-forward Prometheus and open `http://localhost:9090/targets`:
```bash
kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090
```
Success: a long list of scrape targets, all `UP`. Find the `serviceMonitor/kubeshowcase/ks-api`
target — that's your app, discovered automatically.

**2. Write your first PromQL and watch it change.** In the Prometheus UI (Graph tab) run:
```promql
sum by (path) (rate(http_requests_total{namespace="kubeshowcase"}[5m]))
```
Success: per-path request rates. Now generate traffic in another terminal and re-run:
```bash
for i in $(seq 1 50); do curl -sk https://app.192.168.1.27.nip.io/api/items >/dev/null; done
```
Success: the `/api/items` line ticks up. Try the p95 latency query too:
```promql
histogram_quantile(0.95, sum by (le) (rate(http_request_duration_seconds_bucket{namespace="kubeshowcase"}[5m])))
```

**3. Find a ServiceMonitor and prove it controls scraping.**
```bash
kubectl get servicemonitors -A
kubectl -n kubeshowcase get servicemonitor ks-api -o yaml | grep -A4 endpoints
```
Success: you see `port: http`, `path: /metrics`, `interval: 15s` — the exact instructions Prometheus
follows for your app. (Reversible probe: temporarily relabel the Service it selects and watch the
target drop in `/targets`, then revert — only if you're comfortable; otherwise just read it.)

**4. Pivot metric → trace → log in Grafana (the payoff).** Open Grafana (port-forward
`svc/kube-prometheus-stack-grafana 3000:80`, or `https://grafana.192.168.1.27.nip.io`, password via
`sops -d observability/manifests/grafana-admin.sops.yaml`). Generate a little traffic (step 2). Then:
- Open the **"KubeShowcase App"** dashboard → the latency panel. Enable exemplars; click an exemplar
  dot. Success: it offers a link to the **trace** in Tempo.
- In **Explore → Loki**, run `{namespace="kubeshowcase", container="api"} | json | trace_id != ""`.
  Success: JSON log lines with a `trace_id` field; clicking the derived `TraceID` link jumps to Tempo.
- In **Explore → Tempo**, search by service `ks-api`. Success: a trace with spans and timings.

**5. Query logs as metrics with LogQL.** In Explore → Loki:
```logql
sum(rate({namespace="kubeshowcase"}[5m])) by (container)
```
Success: a *graph* (not text) of log lines/sec per container — proof that LogQL turns logs into time
series, exactly like PromQL.

**6. Trigger and observe an alert lifecycle (safe, self-healing).** Look at the rules, then watch one
fire and resolve by scaling a deployment to 0 briefly:
```bash
kubectl -n monitoring get prometheusrule homelab-alerts -o yaml | grep -A2 'alert: PodCrash'
# port-forward Alertmanager and watch its UI:
kubectl port-forward -n monitoring svc/kube-prometheus-stack-alertmanager 9093:9093
# open http://localhost:9093  — see currently-firing/grouped alerts
```
Success: you see the active alert set and how Alertmanager groups by `alertname`/`namespace`
(config in `kube-prometheus-stack.yaml` line 51). For a clean reversible trigger, delete one pod of a
multi-replica deployment (it self-heals) and watch nothing critical fire — confirming the rules are
tuned. (Avoid actually breaking a single-replica stateful component.)

## Check yourself

1. **Why does Prometheus pull (scrape) instead of having apps push?** — Pull gives Prometheus control
   of timing/discovery, makes target health observable via the `up` metric, and avoids apps needing
   to know the monitoring backend's address; push fits short-lived/batch jobs (Pushgateway/OTLP).
2. **Counter vs gauge vs histogram, with an example from this repo?** — Counter only increases
   (`http_requests_total`); gauge goes up/down (`ks_queue_depth`); histogram buckets observations for
   percentiles (`http_request_duration_seconds`). All in `app-src/api/metrics.go`.
3. **What do ServiceMonitor and the Prometheus Operator do?** — The Operator watches for
   ServiceMonitor/PodMonitor/PrometheusRule CRs and rewrites Prometheus's scrape and alert config, so
   you declare *what* to scrape (e.g. `ks-api` selecting `app: ks-api`) instead of editing config.
4. **Difference between node-exporter and kube-state-metrics?** — node-exporter exposes per-node OS
   resource usage (`node_*` from /proc); KSM exposes Kubernetes object state (`kube_*`, e.g. desired
   vs actual replicas, node Ready). Usage vs API state.
5. **How does Loki keep log storage cheap, and what's the cost?** — It indexes only a few labels
   (namespace/pod/container) and stores compressed chunks in object storage (MinIO here); the tradeoff
   is slower full-text needle-in-haystack search than a fully-indexed system like Elasticsearch.
6. **What is a span and a trace ID, and why do they matter?** — A span is one timed unit of work; a
   trace is all spans sharing a trace ID, forming one request's path across services. The trace ID is
   the join key that links a metric exemplar, a log line, and the full trace.
7. **What is Alloy's role versus Loki/Tempo?** — Alloy is the *collector/pipeline* agent (DaemonSet)
   that discovers, relabels, and ships logs to Loki and traces to Tempo; Loki and Tempo are the
   *storage/query backends*. Collector ≠ backend.
8. **What does Alertmanager add that Prometheus alone doesn't?** — Deduplication, grouping, silencing,
   inhibition, and routing to receivers (here, an `ntfy.sh` webhook); Prometheus only *evaluates* the
   rules and fires.

## Where this fits in the path

Do **Module 4 (GitOps/Argo CD)** and **Module 3 (Cilium networking)** first — Argo deploys this whole
stack and Cilium's kube-proxy-free mode explains the disabled scrape targets. After this, tackle the
**autoscaling module** (the HPA consumes prometheus-adapter's custom metrics) and **storage/Longhorn**
(Prometheus's TSDB and Loki/Tempo's MinIO backend live there).
