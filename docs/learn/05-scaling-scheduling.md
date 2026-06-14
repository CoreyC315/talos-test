# Module 5: Scaling, Scheduling & Resources — Making It Elastic

> Production clusters live or die on two questions: *where does each pod land* and *how many of each
> pod do we run right now*. This module is the answer to both. After it you'll be able to read and
> write resource requests/limits and reason about which pods get killed first under pressure; steer
> the scheduler with node selectors, affinity, taints, topology spread and PodDisruptionBudgets;
> stand up three different autoscalers (HPA on CPU *and* a custom Prometheus metric, VPA for
> right-sizing, and KEDA for event-driven scale-to-zero); and explain the metrics plumbing
> (metrics-server, prometheus-adapter, the `custom.metrics.k8s.io` API) that makes it all tick.
> This is the single richest area of the CKA/CKAD exams and the thing platform/SRE interviewers
> probe hardest, because it's where cost and reliability collide.

## The big picture

Kubernetes has two control loops that decide the shape of your workloads:

- **Scheduling** is a one-time placement decision: when a pod is created, the *scheduler* picks a
  node for it. Your job is to give it constraints (this pod needs 100m CPU; keep replicas on
  different hosts; don't put me on control-plane nodes) and let it solve the puzzle.
- **Autoscaling** is a continuous decision: controllers watch metrics and change *how many* pods
  exist (HPA, KEDA — horizontal) or *how big* each pod is (VPA — vertical).

Both loops are fed by **resource requests/limits** (the numbers you promise/cap per container) and by
a **metrics pipeline** that turns raw observability into numbers the autoscalers can read.

```
                 metrics pipeline                         control loops
  ┌──────────────┐   raw CPU/mem    ┌───────────────┐
  │   kubelet    │ ───────────────► │ metrics-server│ ──► kubectl top, HPA (Resource metrics)
  │ (cAdvisor)   │                  └───────────────┘ ──► VPA recommender
  └──────────────┘                                          │
  ┌──────────────┐  http_requests   ┌────────────────────┐  │   ┌─────┐  scaleTargetRef
  │ Prometheus   │ ───────────────► │ prometheus-adapter │ ─┼─► │ HPA │ ──► Deployment/Rollout
  │ (your apps)  │                  │ custom.metrics API │  │   └─────┘     replica count
  └──────────────┘                  └────────────────────┘  │
  ┌──────────────┐  queue length    ┌────────────────────┐  │   ┌──────┐  creates+owns
  │ Redis / Kafka│ ───────────────► │       KEDA         │ ─┴─► │ HPA  │ ──► Deployment (0..N)
  │  / cron / …  │                  │ (external.metrics) │      └──────┘
  └──────────────┘                  └────────────────────┘

  scheduler input: requests + nodeSelector/affinity/taints/topologySpread + PDB (for drains)
```

Notice that **HPA is the hub**: VPA and HPA both exist, but only one may own a given signal at a time,
and KEDA doesn't replace HPA — it *generates* an HPA for you. In this cluster all three run side by
side without conflict, on purpose (`workloads/kubeshowcase/autoscaling.yaml` line 1 documents the
split: HPA→`ks-api`, KEDA→`ks-worker`, VPA→`ks-frontend`).

Throughout, the live cluster is reachable after:

```bash
export KUBECONFIG=$PWD/terraform/.kubeconfig
```

## Tools in this module

### Resource requests/limits and QoS classes — the contract between a pod and the node

- **What it is / mental model:** A **request** is the amount of CPU/memory you *reserve* for a
  container — the scheduler subtracts it from a node's allocatable capacity and won't place the pod
  unless it fits. A **limit** is the *ceiling* — exceed the memory limit and the kernel OOM-kills the
  container; exceed the CPU limit and you get *throttled* (slowed), not killed. Analogy: a request is
  the table you booked at a restaurant (reserved whether or not you show up); the limit is the
  maximum number of plates the kitchen will serve you before cutting you off. **QoS class**
  (Guaranteed / Burstable / BestEffort) is a label Kubernetes derives from those numbers that decides
  *eviction order* when a node runs out of memory.
- **How it works:** CPU is *compressible* (throttled with no data loss); memory is *incompressible*
  (the only way to reclaim it is to kill). QoS is computed per pod: **Guaranteed** = every container
  sets requests == limits for *both* cpu and memory; **BestEffort** = no requests or limits anywhere;
  **Burstable** = anything in between. Under node memory pressure the kubelet evicts BestEffort first,
  then Burstable that's over its request, and Guaranteed last. The scheduler only ever looks at
  *requests*; limits are enforced at runtime by the kernel (cgroups). A **LimitRange** can inject
  default requests/limits into containers that forgot them, and a **ResourceQuota** caps the
  *namespace total*.
- **In THIS cluster:**
  - Real numbers: `workloads/kubeshowcase/api.yaml` — the `api` container sets
    `requests: {cpu: 100m, memory: 64Mi}` and `limits: {cpu: "1", memory: 192Mi}` (Burstable: requests
    ≠ limits). `100m` means 0.1 of a CPU core ("100 millicores"). `64Mi` is 64 mebibytes.
  - The namespace guardrails live in `workloads/kubeshowcase/quota.yaml`: a `ResourceQuota`
    (`requests.cpu: "3"`, `limits.memory: 8Gi`, `pods: "40"`, …) and a `LimitRange` that defaults any
    container with no limits to `cpu: 500m / memory: 256Mi`.
  - Live — see QoS classes and the quota in action:
    ```bash
    kubectl get pods -n kubeshowcase \
      -o custom-columns='POD:.metadata.name,QOS:.status.qosClass'
    kubectl describe resourcequota kubeshowcase-quota -n kubeshowcase
    ```
    Look for `Burstable` next to `ks-api`/`ks-frontend`, and in the quota the `Used / Hard` columns
    (e.g. `requests.cpu  ~750m / 3`). If `Used` ever hit `Hard`, new pods would be *rejected at admission*.
- **Job relevance:** Near-guaranteed interview question: "what's the difference between a request and
  a limit, and what happens when each is exceeded?" (answer: scheduler vs kernel; throttle vs
  OOMKill). Follow-ups: "explain the three QoS classes and eviction order," "why is setting a CPU
  limit sometimes harmful?" (throttling latency). Heavily tested on **CKA** (resource management,
  LimitRange/ResourceQuota) and **CKAD** (defining requests/limits is core).
- **Learn it:** kubernetes.io → search "Resource Management for Pods and Containers" and "Configure
  Quality of Service for Pods". For the namespace guardrails, kubernetes.io → "Resource Quotas" and
  "Limit Ranges".

### The scheduler — deciding which node every pod lands on

- **What it is / mental model:** `kube-scheduler` is the matchmaker. For every unscheduled pod it runs
  two phases — **filtering** (which nodes *could* host this pod? eliminate ones that don't fit
  requests, fail a nodeSelector, or have a taint the pod doesn't tolerate) and **scoring** (of the
  survivors, which is *best*? spread, affinity, least-loaded…). The highest-scoring node wins and the
  pod is *bound* to it. Analogy: a seating host who first crosses off tables that are too small or
  reserved (filter), then picks the nicest remaining table by your preferences (score). You influence
  it with declarative hints on the pod.
- **How it works — the levers you'll use:**
  - **nodeSelector / nodeAffinity:** "only schedule me on nodes with label X." `nodeSelector` is a hard
    exact-match; `nodeAffinity` adds `required` (hard) vs `preferred` (soft) and richer operators.
  - **podAffinity / podAntiAffinity:** schedule me *near* (or *away from*) pods matching a label —
    e.g. anti-affinity to keep replicas off the same node.
  - **Taints & tolerations:** a **taint** on a *node* repels pods ("`NoSchedule`"); a **toleration** on a
    *pod* is the permission slip that lets it land there anyway. This is how control-plane nodes keep
    ordinary workloads off. (Taints repel; affinity attracts — they're opposite tools.)
  - **topologySpreadConstraints:** "spread my replicas evenly across a topology domain" (hostname,
    zone) with a `maxSkew` (max allowed imbalance) and `whenUnsatisfiable: DoNotSchedule` (hard) or
    `ScheduleAnyway` (soft preference).
  - **PodDisruptionBudget (PDB):** not a *placement* rule but a *disruption* rule — it tells
    `kubectl drain` / the eviction API "you may never take me below `minAvailable` voluntarily." It
    protects against *voluntary* disruptions (drains, upgrades), not crashes.
- **In THIS cluster:**
  - Control-plane nodes carry the standard taint `node-role.kubernetes.io/control-plane:NoSchedule`,
    which is why app pods only run on `worker-1/2/3`.
  - Topology spread: `workloads/kubeshowcase/api.yaml` spreads `ks-api` across **both**
    `kubernetes.io/hostname` and `topology.kubernetes.io/zone` (`maxSkew: 1`, `ScheduleAnyway`).
    `frontend.yaml` spreads across hostname only. The zone labels come from the Proxmox host —
    `worker-1=aether, worker-2=nahida, worker-3=raiden` (also seen on the control-plane nodes).
  - PDBs in `workloads/kubeshowcase/pdb.yaml`: `ks-api` and `ks-frontend` use `minAvailable: 1`;
    `redis` uses `maxUnavailable: 1` *on purpose* — a single-replica pod with `minAvailable: 1` would
    **deadlock a node drain** (the file comments this; it's a classic production footgun).
  - Live — see taints, zones, and the resulting spread:
    ```bash
    kubectl get nodes \
      -o custom-columns='NAME:.metadata.name,TAINTS:.spec.taints'
    kubectl get nodes -L topology.kubernetes.io/zone
    kubectl get pods -n kubeshowcase -o wide          # NODE column: api replicas on different hosts
    kubectl get pdb -n kubeshowcase
    ```
    Look for the `control-plane:NoSchedule` taint on `cp-1/2/3` only, distinct zones, `ks-api` pods on
    two different worker NODEs, and `ALLOWED DISRUPTIONS` in the PDB output.
- **Job relevance:** This is *the* scheduling interview block. Expect: "node affinity vs nodeSelector
  vs taints — when each?"; "how do you guarantee replicas don't share a node/zone?" (anti-affinity or
  topology spread); "what does a PDB do and how can a bad PDB break a drain?" (your redis example is
  the exact gotcha). **CKA** tests scheduling, taints/tolerations, and node selection directly.
- **Learn it:** kubernetes.io → "Assigning Pods to Nodes" (nodeSelector/affinity), "Taints and
  Tolerations", "Pod Topology Spread Constraints", and "Specifying a Disruption Budget for your
  Application". Practice `kubectl explain pod.spec.affinity` to discover the field shape.

### metrics-server — the cluster's CPU/memory pulse for `kubectl top` and the HPA

- **What it is / mental model:** A lightweight in-memory service that scrapes every kubelet for the
  *current* CPU and memory of every pod/node and serves it through the standard `metrics.k8s.io`
  API. It is the heart-rate monitor: it tells you what's happening *right now*, keeps no history, and
  is the data source for `kubectl top` and any HPA `Resource` metric (CPU/memory %). Do **not**
  confuse it with Prometheus (which stores history and arbitrary app metrics) — metrics-server is
  just the live CPU/mem feed.
- **How it works:** It registers itself as an **APIService** so the kube-apiserver *aggregates*
  requests to `/apis/metrics.k8s.io/...` straight to the metrics-server pod (this "aggregation layer"
  pattern is reused by prometheus-adapter and KEDA below). Every ~15s it pulls the kubelet's
  `/metrics/resource` endpoint. No metrics-server → `kubectl top` errors and CPU-based HPAs read
  `<unknown>` and can't scale.
- **In THIS cluster:**
  - Installed via Argo CD: `apps/platform/metrics-server.yaml` (Helm chart `3.13.1`, sync-wave `2`).
    Note the one Talos-specific flag: `--kubelet-insecure-tls`, because Talos kubelet serving certs
    are self-signed by default — a real, repo-grounded gotcha worth remembering.
  - Live:
    ```bash
    kubectl top nodes
    kubectl top pods -n kubeshowcase
    kubectl get apiservice v1beta1.metrics.k8s.io   # AVAILABLE should be True
    ```
    `kubectl top nodes` should print real CPU(%) / MEMORY(%) per node (you saw worker-2 ~62% mem).
    If `top` ever errors, the APIService row is where you start debugging.
- **Job relevance:** "Why does `kubectl top` say `error: metrics not available`?" and "what feeds a
  CPU-based HPA?" are common. Knowing it uses the *aggregation layer* (not a separate port) separates
  people who've operated clusters from those who've only read about them. **CKA** expects you to
  install/troubleshoot it.
- **Learn it:** GitHub `kubernetes-sigs/metrics-server` README (search "metrics-server kubernetes
  sigs"). kubernetes.io → "Resource metrics pipeline" and "Tools for Monitoring Resources".

### Horizontal Pod Autoscaler (HPA) — add/remove pod replicas to match load

- **What it is / mental model:** A controller that watches a metric and changes a workload's
  `replicas` to keep that metric near a target. Analogy: a thermostat for pods — set "keep CPU at
  60%," and it adds replicas when you're hot, removes them when you're cool, between a `min` and `max`.
- **How it works:** Every ~15s the HPA reads the metric, computes
  `desiredReplicas = ceil(currentReplicas × currentMetric / targetMetric)`, clamps it to
  `[min,max]`, and patches the target's replica count. `autoscaling/v2` supports multiple metrics at
  once (it takes the **max** of the desired counts so the busiest signal wins) and several types:
  `Resource` (CPU/mem from metrics-server), `Pods` and `Object` (custom metrics via the adapter),
  `External` (KEDA's lane). A `behavior` block adds **stabilization windows** to damp flapping
  (scale up fast, scale down slow). It does not have to target a Deployment — anything with a
  `/scale` subresource works, including an Argo Rollout.
- **In THIS cluster:**
  - `workloads/kubeshowcase/autoscaling.yaml` defines the `ks-api` HPA: `minReplicas: 2`,
    `maxReplicas: 6`, **two** metrics — `Resource` CPU at `60%` *and* `Pods` custom metric
    `http_requests_per_second` at avg `20` (this is what makes the demo interesting: it scales on
    *requests per second*, not just CPU). Note `scaleTargetRef` is `kind: Rollout` (Argo Rollouts),
    not a Deployment — a great talking point. `behavior` scales up after a 30s window, down after 120s.
  - Live — watch it think:
    ```bash
    kubectl get hpa ks-api -n kubeshowcase
    kubectl describe hpa ks-api -n kubeshowcase | sed -n '/Metrics:/,/Events:/p'
    ```
    The `TARGETS` column shows both signals, e.g. `cpu: 1%/60%, 366m/20` — the second pair is
    live requests-per-second vs the target of 20. (`366m` = 0.366 req/s.)
- **Job relevance:** "Walk me through the HPA algorithm" (the ceil formula), "what metrics can an HPA
  scale on?", "HPA vs VPA — can they coexist?" (not on the same resource signal), and "how do you stop
  it flapping?" (`behavior` stabilization). Core on **CKAD** and **CKA**.
- **Learn it:** kubernetes.io → "Horizontal Pod Autoscaling" (the concept + the algorithm details
  section) and "HorizontalPodAutoscaler Walkthrough".

### Custom metrics via prometheus-adapter — let the HPA scale on *your app's* numbers

- **What it is / mental model:** metrics-server only knows CPU and memory. But you often want to scale
  on a *business* signal — requests per second, queue depth, p95 latency. prometheus-adapter is a
  translator: it sits in front of Prometheus and exposes selected PromQL queries through the standard
  `custom.metrics.k8s.io` API, so the HPA can read them exactly like it reads CPU. Analogy: a
  universal-remote dongle that makes your weird-protocol Prometheus speak the standard Kubernetes
  "metrics" language the HPA already understands.
- **How it works:** Like metrics-server, it registers as an **APIService**
  (`v1beta1.custom.metrics.k8s.io`) on the aggregation layer. A **rules** config maps Prometheus
  series → Kubernetes metric names and tells the adapter how to associate a series with pods/namespaces
  (via label `overrides`) and what PromQL to run for a value. When the HPA asks "what's
  `http_requests_per_second` for these pods?", the adapter substitutes the pod/namespace into the
  configured `metricsQuery` and returns the number.
- **In THIS cluster:**
  - `apps/observability/prometheus-adapter.yaml` (Helm `5.3.0`, sync-wave `4`). The single custom rule:
    - `seriesQuery: 'http_requests_total{namespace!="",pod!=""}'`
    - renamed via `name.matches: "^(.*)_total$" → as: "http_requests_per_second"`
    - `metricsQuery: 'sum(rate(<<.Series>>{<<.LabelMatchers>>}[2m])) by (<<.GroupBy>>)'`

    So `http_requests_total` (a counter your Go API emits, scraped by the ServiceMonitors in
    `workloads/kubeshowcase/servicemonitors.yaml`) becomes the per-pod *rate* `http_requests_per_second`
    that the `ks-api` HPA targets. There's a load-bearing ops note in the file: it was **OOMKilled at
    512Mi** once full observability came back (2-day retention = more series to load on startup), so
    the memory limit was raised to `1Gi`.
  - Live — query the custom-metrics API directly (this is exactly what the HPA does):
    ```bash
    kubectl get --raw /apis/custom.metrics.k8s.io/v1beta1 | jq '.resources[].name' | grep http_requests
    kubectl get --raw \
      "/apis/custom.metrics.k8s.io/v1beta1/namespaces/kubeshowcase/pods/*/http_requests_per_second" | jq
    ```
    The second command returns one `value` per `ks-api` pod (e.g. `"value":"371m"` = 0.371 req/s).
    That's the live number flowing into the HPA.
- **Job relevance:** "How do you autoscale on something Prometheus knows but Kubernetes doesn't?" — the
  expected answer *is* prometheus-adapter + `custom.metrics.k8s.io`. Bonus points for knowing it's the
  same aggregation-layer pattern as metrics-server, and for the `seriesQuery`/`metricsQuery` mental
  model. Not on a cert by name, but the "custom metrics HPA" concept appears in CKAD-adjacent material.
- **Learn it:** GitHub `kubernetes-sigs/prometheus-adapter` — README and `docs/config.md` (search
  "prometheus-adapter config walkthrough"). kubernetes.io → "Support for metrics APIs" (the
  custom/external metrics API section).

### Vertical Pod Autoscaler (VPA) + Goldilocks — right-sizing requests/limits instead of pod counts

- **What it is / mental model:** HPA changes *how many* pods; VPA changes *how big* each pod is. It
  observes a workload's real CPU/memory usage over time and recommends (or applies) better
  requests/limits. **Goldilocks** is a dashboard that runs a VPA in *recommend-only* mode for every
  workload in opted-in namespaces and shows you the suggested numbers — perfect for the "is this pod
  over- or under-provisioned?" question without VPA actually touching anything. Analogy: VPA is a
  tailor who measures you and re-cuts the suit; Goldilocks is the fitting-room mirror showing what
  size you *should* be wearing.
- **How it works:** VPA has three components — **recommender** (computes target requests from usage
  history), **updater** (evicts pods whose requests are too far off so they reschedule with new
  values), and **admission controller** (a mutating webhook that injects the recommended requests as
  the pod is created). `updateMode` controls behavior: `Off` (recommend only — what Goldilocks uses),
  `Initial` (set at creation only), `Auto`/`Recreate` (evict + recreate to apply). Newer VPA + the
  in-place pod resize feature can resize *without* recreating. **Critical rule:** never point a VPA and
  an HPA at the *same* CPU/memory signal — they'll fight (VPA raises requests, which changes CPU%,
  which moves the HPA, …). That's why this repo deliberately keeps them on different workloads.
- **In THIS cluster:**
  - Operators installed via `apps/workload-operators/vpa-goldilocks.yaml` (Fairwinds `vpa 4.7.2` +
    `goldilocks 10.4.0`, sync-wave `6`). Goldilocks is enabled on the `kubeshowcase` namespace by the
    label `goldilocks.fairwinds.com/enabled: "true"` in `workloads/kubeshowcase/namespace.yaml`.
  - The *active* VPA targets `ks-frontend` (`workloads/kubeshowcase/autoscaling.yaml`,
    `kind: VerticalPodAutoscaler`, `updateMode: Auto`, bounded by
    `minAllowed: {cpu: 10m, memory: 32Mi}` / `maxAllowed: {cpu: 200m, memory: 256Mi}`). The file
    comment notes the desired `InPlaceOrRecreate` mode needs VPA ≥1.5; `Auto` still demonstrates it.
    `ks-frontend` is deliberately **not** HPA-managed (the file says so), to honour the no-shared-signal rule.
  - Live:
    ```bash
    kubectl get vpa -n kubeshowcase            # ks-frontend is Auto; goldilocks-* are Off (recommend)
    kubectl describe vpa ks-frontend -n kubeshowcase | sed -n '/Recommendation/,/Events/p'
    kubectl describe vpa goldilocks-ks-api -n kubeshowcase | sed -n '/Recommendation/,$p'
    ```
    Look for the `Target` / `Lower Bound` / `Upper Bound` recommendation block. The `goldilocks-*` VPAs
    (mode `Off`) are how the dashboard gets its numbers. Or open the UI:
    `https://goldilocks.192.168.1.27.nip.io`.
- **Job relevance:** "HPA vs VPA, and why can't they share a metric?" is a frequent trap. "How do you
  right-size a fleet you didn't design?" → VPA recommendations / Goldilocks. Know the three VPA
  components and the four update modes. Not directly on a cert by name, but resource right-sizing is a
  bread-and-butter SRE/FinOps interview theme.
- **Learn it:** GitHub `kubernetes/autoscaler` → `vertical-pod-autoscaler` README (search "vertical pod
  autoscaler README", covers the recommender/updater/admission split and update modes). Fairwinds docs
  → search "Goldilocks docs Fairwinds".

### KEDA — event-driven autoscaling and scale-to-zero

- **What it is / mental model:** Plain HPA can't scale to **zero** and can't natively read "external"
  signals like *Redis queue length* or *Kafka lag*. KEDA (Kubernetes Event-Driven Autoscaling) fills
  both gaps. You declare a `ScaledObject` saying "watch this Redis list; run between 0 and 5 worker
  pods." Analogy: a smart power strip for a workload — when there's nothing to do it cuts the pod count
  to **zero** (free), and the instant work shows up it powers pods back on. Perfect for queue
  consumers, batch workers, and anything bursty.
- **How it works:** KEDA has two pieces. The **operator** watches `ScaledObject`s and, for each one,
  *creates and manages a normal HPA* under the hood (so you keep all HPA machinery) — but it owns the
  `0↔1` transition itself via an "activation" check, because stock HPA can't go to zero. KEDA's
  **metrics adapter** registers on the aggregation layer as `external.metrics.k8s.io` and feeds the
  generated HPA the scaler's value (queue length). A **trigger** names the source (`redis`, `kafka`,
  `prometheus`, `cron`, dozens more) plus the thresholds. When the queue is empty and below
  `activationListLength`, KEDA scales the Deployment to 0; when items appear, it activates back to ≥1
  and the HPA takes over from there up to `maxReplicaCount`.
- **In THIS cluster:**
  - Operator via `apps/workload-operators/keda.yaml` (Helm `keda 2.20.1`, sync-wave `6`).
  - The `ScaledObject` is in `workloads/kubeshowcase/autoscaling.yaml`: targets `ks-worker`,
    `minReplicaCount: 0` (scale-to-zero), `maxReplicaCount: 5`, `pollingInterval: 10s`,
    `cooldownPeriod: 60s`, trigger `type: redis` on list `jobs` at
    `redis.kubeshowcase.svc.cluster.local:6379` with `listLength: "5"` (one pod per ~5 queued jobs).
  - The worker (`workloads/kubeshowcase/worker.yaml`) ships with `replicas: 0` and a comment "KEDA owns
    the replica count" — important, because if you set a static replica count *and* a KEDA min of 0
    they'd argue. The worker `BRPOP`s jobs off the `jobs` list (see `app-src/worker/main.go`).
  - Live — see the ScaledObject and the HPA KEDA generated *for* it:
    ```bash
    kubectl get scaledobject -n kubeshowcase
    kubectl get hpa -n kubeshowcase                 # note keda-hpa-ks-worker — created BY keda
    kubectl get deploy ks-worker -n kubeshowcase    # READY 0/0 when the queue is empty
    ```
    When idle you'll see `ks-worker` at `0/0` and a `keda-hpa-ks-worker` HPA whose target is `5`. That
    `keda-` prefixed HPA being machine-generated is the whole insight.
- **Job relevance:** "How do you scale a queue worker to zero?" → KEDA (stock HPA can't). "What does
  KEDA actually do — does it replace the HPA?" → no, it *generates* one and owns the 0↔1 hop via
  `external.metrics.k8s.io`. Knowing the trigger catalogue (Kafka lag, SQS, cron) signals real
  event-driven experience. Increasingly common in platform/SRE interviews; not on CKA/CKAD/CKS.
- **Learn it:** keda.sh → "Concepts" (Scaling Deployments / ScaledObject spec) and the "Scalers"
  catalogue (find the Redis Lists scaler to match this repo). keda.sh → "FAQ" for the
  "does KEDA replace HPA" answer.

## Hands-on lab (on YOUR cluster)

All exercises assume `export KUBECONFIG=$PWD/terraform/.kubeconfig`. Everything here is
non-destructive or trivially reversible.

### Lab 1 — Read the resource contract and QoS

```bash
kubectl get pods -n kubeshowcase \
  -o custom-columns='POD:.metadata.name,QOS:.status.qosClass,NODE:.spec.nodeName'
kubectl get deploy ks-api -n kubeshowcase \
  -o jsonpath='{.spec.template.spec.containers[0].resources}{"\n"}' 2>/dev/null \
  || kubectl get rollout ks-api -n kubeshowcase \
       -o jsonpath='{.spec.template.spec.containers[0].resources}{"\n"}'
kubectl describe resourcequota kubeshowcase-quota -n kubeshowcase
```
**Success:** every app pod shows `Burstable`; you can read `requests {cpu:100m,memory:64Mi}` and
`limits {cpu:1,memory:192Mi}` for the api; the quota shows `Used` well under `Hard`. *Now reason:* why
is none of them `Guaranteed`? (requests ≠ limits.)

### Lab 2 — Watch the scheduler's placement, taints, and spread

```bash
kubectl get nodes -o custom-columns='NAME:.metadata.name,TAINTS:.spec.taints'
kubectl get pods -n kubeshowcase -l app=ks-api -o wide      # NODE column
```
**Success:** only `cp-1/2/3` carry the `control-plane:NoSchedule` taint; the two `ks-api` replicas sit
on *different* worker nodes — that's `topologySpreadConstraints` (hostname) at work. Confirm the soft
nature: it's `ScheduleAnyway`, so under pressure they *could* co-locate. *Probe (safe):* add a label
to a node and watch nothing break, then remove it:
```bash
kubectl label node worker-1 demo.lab/scratch=true
kubectl get nodes -L demo.lab/scratch
kubectl label node worker-1 demo.lab/scratch-          # the trailing - removes it
```

### Lab 3 — Drive the HPA with real load and watch it scale

Open a watcher in one terminal:
```bash
kubectl get hpa ks-api -n kubeshowcase -w
```
In another, generate load. Cleanest option is the repo's k6 profile through the Gateway (it ramps API
traffic *and* queues jobs, so it exercises both HPA and KEDA):
```bash
# The job manifest creates the 'loadtest' namespace; apply it first, then inject the script.
kubectl apply -f load-and-chaos/k6-job.yaml
kubectl create configmap k6-script -n loadtest \
  --from-file=k6-load.js=load-and-chaos/k6-load.js --dry-run=client -o yaml \
  | kubectl apply -f -
kubectl logs -n loadtest job/k6-load -f          # ctrl-C to stop watching logs (job keeps running)
```
(If the Job pod started before the ConfigMap existed, just delete and re-apply the job:
`kubectl delete -f load-and-chaos/k6-job.yaml && kubectl apply -f load-and-chaos/k6-job.yaml`.)
**Success:** within a minute the HPA `TARGETS` climb (the `…/20` requests-per-second pair and/or
`cpu …/60%`), `REPLICAS` rises from 2 toward 6, then — thanks to the 120s scale-down stabilization —
drifts back to 2 after the ramp ends. **Cleanup:**
`kubectl delete -f load-and-chaos/k6-job.yaml && kubectl delete cm k6-script -n loadtest`.

### Lab 4 — Inspect the custom-metrics pipeline directly

```bash
kubectl get --raw /apis/custom.metrics.k8s.io/v1beta1 | jq '.resources[].name' | grep http_requests
kubectl get --raw \
  "/apis/custom.metrics.k8s.io/v1beta1/namespaces/kubeshowcase/pods/*/http_requests_per_second" | jq
```
**Success:** the first command lists `pods/http_requests_per_second`; the second returns a `value` per
`ks-api` pod (e.g. `"371m"`). You are reading the *exact* number the HPA's second metric consumes.
*Bonus:* run Lab 3's load and re-run this — watch the values jump.

### Lab 5 — Trigger KEDA scale-from-zero by hand

Observe the worker asleep, then push jobs onto the Redis list it watches:
```bash
kubectl get deploy ks-worker -n kubeshowcase             # expect 0/0
# enqueue 50 jobs straight onto the 'jobs' list KEDA is watching:
kubectl exec -n kubeshowcase deploy/redis -- \
  sh -c 'for i in $(seq 1 50); do redis-cli LPUSH jobs "job-$i" >/dev/null; done; redis-cli LLEN jobs'
kubectl get deploy ks-worker -n kubeshowcase -w          # watch READY climb 0 -> N
```
**Success:** `LLEN jobs` prints ~50, then within `pollingInterval` (10s) `ks-worker` scales up
(toward 5, since 50/5≈10 capped at `maxReplicaCount`), processes the list, and after the 60s
`cooldownPeriod` drops back to `0/0`. Reversible by design — the workers drain the queue themselves;
to abort early, `kubectl exec -n kubeshowcase deploy/redis -- redis-cli DEL jobs`.

### Lab 6 — Read VPA right-sizing recommendations (no apply)

```bash
kubectl get vpa -n kubeshowcase
kubectl describe vpa goldilocks-ks-api -n kubeshowcase | sed -n '/Recommendation/,$p'
```
**Success:** the `goldilocks-*` VPAs are mode `Off` (recommend-only); the recommendation block shows
`Target`, `Lower Bound`, `Upper Bound` for cpu/memory. Compare the `Target` to the *actual* requests
you read in Lab 1 — is `ks-api` over- or under-provisioned? Open `https://goldilocks.192.168.1.27.nip.io`
to see the same data as a dashboard.

## Check yourself

1. **Q:** What's the difference between a resource *request* and a *limit*, and what happens when each
   is exceeded? **A:** Request = reserved capacity the scheduler honors; limit = runtime ceiling.
   Exceed memory limit → OOMKilled; exceed CPU limit → throttled (not killed).
2. **Q:** Name the three QoS classes and the rule that produces each. **A:** Guaranteed (requests==limits
   for cpu *and* mem on every container), BestEffort (no requests/limits at all), Burstable
   (everything else); BestEffort is evicted first.
3. **Q:** Taints vs (anti-)affinity — which repels and which attracts? **A:** A taint on a node repels
   pods that lack a matching toleration; affinity attracts/repels based on pod or node labels. They're
   opposite tools.
4. **Q:** Why does the `redis` PDB use `maxUnavailable: 1` instead of `minAvailable: 1`? **A:** Redis is
   a single replica; `minAvailable: 1` would forbid evicting it ever, deadlocking node drains/upgrades.
5. **Q:** What feeds a CPU-based HPA, and what feeds an HPA scaling on `http_requests_per_second`?
   **A:** metrics-server (via `metrics.k8s.io`) for CPU; prometheus-adapter (via `custom.metrics.k8s.io`)
   for the request-rate metric.
6. **Q:** Can a VPA and an HPA both manage the same Deployment? **A:** Not on the same signal — VPA
   changing CPU requests moves the HPA's CPU%, so they fight; that's why this repo splits them across
   `ks-frontend` (VPA) and `ks-api` (HPA).
7. **Q:** Does KEDA replace the HPA? **A:** No — for each `ScaledObject` it *creates and manages* an HPA
   (`keda-hpa-*`) and only owns the 0↔1 transition itself via the external-metrics API.
8. **Q:** When two HPA metrics disagree on the desired replica count, which wins? **A:** The larger one —
   the HPA takes the max across metrics so the busiest signal governs.

## Where this fits in the path

**Before this:** be comfortable with Deployments/Pods, namespaces, Services, and basic `kubectl`
(Module on Core Workloads), and have a working metrics/Prometheus picture (the Observability module) —
the custom-metrics HPA depends on it. **After this:** progress to rollout strategies and progressive
delivery (Argo Rollouts canary + the `AnalysisTemplate` already in `api.yaml`), and to
resilience/chaos (node drains exercise the PDBs and topology spread you set up here).
