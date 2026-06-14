# metrics-server
> The cluster's live CPU/memory pulse — the data source behind `kubectl top` and CPU-based autoscaling.

**What it is.** A lightweight, in-memory service that scrapes every [[kubelet]] for the *current* CPU and memory of every pod and node, serving it through the standard `metrics.k8s.io` API. It's a heart-rate monitor: it tells you what's happening right now and keeps **no history**. Don't confuse it with [[prometheus]] (which stores history and arbitrary app metrics) — metrics-server is only the live CPU/mem feed.

**How it works.** It registers as an **APIService** so the [[kube-apiserver]] *aggregates* requests to `/apis/metrics.k8s.io/...` straight to the metrics-server pod — the same "aggregation layer" pattern reused by [[prometheus-adapter]] and [[keda]]. Every ~15s it pulls each kubelet's `/metrics/resource` endpoint. No metrics-server → `kubectl top` errors and CPU-based [[hpa|HPAs]] read `<unknown>` and can't scale.

**In this cluster.**
- Installed via [[argo-cd|Argo CD]]: `apps/platform/metrics-server.yaml` (Helm `3.13.1`, sync-wave `2`). One Talos-specific flag: `--kubelet-insecure-tls`, because [[talos-linux|Talos]] kubelet serving certs are self-signed.
- Live: `kubectl top nodes` and `kubectl get apiservice v1beta1.metrics.k8s.io` (AVAILABLE should be `True`).

**See also:** [[hpa]] · [[prometheus-adapter]] · [[vpa-goldilocks]] · [[requests-and-limits]] · [[kubelet]] · [[prometheus]] &nbsp; **Deep dive:** [[05-scaling-scheduling]]
