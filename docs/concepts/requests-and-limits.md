# Requests & Limits (QoS)
> The per-container contract for CPU/memory that drives scheduling, throttling, OOM-kills, and eviction order.

**What it is.** A **request** is the CPU/memory you reserve — the [[kube-scheduler|scheduler]] subtracts it from a node's allocatable capacity and won't place the pod unless it fits. A **limit** is the runtime ceiling. Analogy: the request is the restaurant table you booked (reserved whether you show up or not); the limit is the most plates the kitchen will serve before cutting you off. **QoS class** (Guaranteed / Burstable / BestEffort) is a label Kubernetes derives from these numbers that decides eviction order under memory pressure.

**How it works.** CPU is *compressible* — exceed the CPU limit and you're throttled (slowed), not killed. Memory is *incompressible* — exceed the memory limit and the kernel OOM-kills the container. QoS is computed per pod: **Guaranteed** = requests==limits for cpu *and* memory on every container; **BestEffort** = nothing set anywhere; **Burstable** = in between. Under node memory pressure the [[kubelet]] evicts BestEffort first, then Burstable over its request, Guaranteed last. The scheduler only reads *requests*; limits are enforced at runtime by the kernel (cgroups). A `LimitRange` injects defaults; a `ResourceQuota` caps the namespace total.

**In this cluster.**
- Real numbers: `workloads/kubeshowcase/api.yaml` — the `api` container sets `requests: {cpu: 100m, memory: 64Mi}`, `limits: {cpu: "1", memory: 192Mi}` (Burstable).
- Namespace guardrails: `workloads/kubeshowcase/quota.yaml` — a `ResourceQuota` (`requests.cpu: "3"`, `limits.memory: 8Gi`, `pods: "40"`) plus a `LimitRange` defaulting unset containers to `cpu: 500m / memory: 256Mi`.
- Live: `kubectl get pods -n kubeshowcase -o custom-columns='POD:.metadata.name,QOS:.status.qosClass'`

**See also:** [[scheduling-constraints]] · [[hpa]] · [[vpa-goldilocks]] · [[metrics-server]] · [[pod-security-standards]] &nbsp; **Deep dive:** [[05-scaling-scheduling]]
