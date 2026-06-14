# node-exporter
> A per-node agent that exposes a machine's OS-level health (CPU, memory, disk, network) as Prometheus metrics by reading Linux `/proc` and `/sys`.

**What it is.** Prometheus only scrapes things that expose `/metrics`, but a bare machine doesn't. node-exporter fills that gap: it runs on every node (a **DaemonSet**) and exposes the *machine's* health — CPU, memory, disk, filesystem, network — read from Linux `/proc` and `/sys`. Analogy: the dashboard gauges in a car, one set per physical engine. (Its counterpart, kube-state-metrics, exposes the Kubernetes API's *object state* like desired-vs-actual replicas — don't confuse the two: usage vs. API state.)

**How it works.** node-exporter is a plain HTTP server exposing `/metrics`; the bundle ships a ServiceMonitor so Prometheus scrapes it automatically. Its metrics are prefixed `node_` (e.g. `node_memory_MemAvailable_bytes`), which the cluster's alert rules lean on. Because it needs `hostNetwork`/`hostPID`/`hostPath` to read the host, it runs with elevated host access — which collides with restrictive Pod Security Admission.

**In this cluster.**
- Enabled via `prometheus-node-exporter` in `apps/observability/kube-prometheus-stack.yaml`. The `monitoring` namespace is labeled `pod-security.kubernetes.io/enforce: privileged` there *specifically* so the node-exporter DaemonSet isn't rejected (the cluster default PSA is `baseline`, which forbids hostNetwork/hostPath).
- `export KUBECONFIG=$PWD/terraform/.kubeconfig && kubectl get pods -n monitoring -l app.kubernetes.io/name=prometheus-node-exporter -o wide` — exactly one pod per node, each on the node's real host IP.

**See also:** [[prometheus]] · [[observability-pillars]] · [[pod-security-standards]] · [[metrics-server]] · [[talos-linux]] &nbsp; **Deep dive:** [[06-observability]] · see [[OPERATIONS]]
