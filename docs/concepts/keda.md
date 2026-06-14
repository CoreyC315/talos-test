# KEDA
> Event-driven autoscaling — scale-to-zero and scaling on external signals like queue length, which plain HPA can't do.

**What it is.** Plain [[hpa|HPA]] can't scale to **zero** and can't natively read external signals like [[redis|Redis]] queue length or Kafka lag. KEDA (Kubernetes Event-Driven Autoscaling) fills both gaps. You declare a `ScaledObject` — "watch this Redis list; run 0 to 5 worker pods." Analogy: a smart power strip for a workload — when there's nothing to do it cuts pods to zero (free), and the instant work shows up it powers them back on.

**How it works.** KEDA has two pieces. The **operator** watches `ScaledObject`s and *creates and manages a normal HPA* under the hood for each one — but owns the `0↔1` transition itself via an "activation" check, since stock HPA can't go to zero. KEDA's **metrics adapter** registers on the [[kube-apiserver]] aggregation layer as `external.metrics.k8s.io` and feeds the generated HPA the scaler's value. A **trigger** names the source (`redis`, `kafka`, `prometheus`, `cron`, dozens more) plus thresholds.

**In this cluster.**
- Operator via [[argo-cd|Argo CD]]: `apps/workload-operators/keda.yaml` (Helm `keda 2.20.1`, sync-wave `6`).
- The `ScaledObject` in `workloads/kubeshowcase/autoscaling.yaml` targets `ks-worker`: `minReplicaCount: 0`, `maxReplicaCount: 5`, trigger `type: redis` on list `jobs` at `listLength: "5"`. The worker (`worker.yaml`) ships `replicas: 0` ("KEDA owns the replica count").
- Live: `kubectl get scaledobject -n kubeshowcase` and `kubectl get hpa -n kubeshowcase` (note `keda-hpa-ks-worker`, created *by* KEDA).

**See also:** [[hpa]] · [[redis]] · [[prometheus-adapter]] · [[metrics-server]] · [[vpa-goldilocks]] &nbsp; **Deep dive:** [[05-scaling-scheduling]]
