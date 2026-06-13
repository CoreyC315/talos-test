# Autoscaling demo — captured results

## KEDA scale-to-zero (event-driven, Redis list length) — VERIFIED LIVE
Worker `ks-worker` runs at **0 replicas** when idle; KEDA's Redis scaler (`listName: jobs`,
`listLength: 5`) wakes it on demand and returns it to zero after the cooldown.

| Time (UTC) | KEDA Active | worker replicas | queue depth | event |
|---|---|---|---|---|
| 16:37:07 | — | 0 | — | 60 jobs queued via `POST /api/items` |
| 16:37:12 | True | **0→4** | 30 | KEDA activates, scales up |
| 16:37:37 | True | **5** (max) | ~ | at maxReplicaCount |
| 16:38:08 | True | 5 (2 ready) | 4 | workers draining the list |
| 16:38:19 | False | 5 | **0** | queue drained |
| 16:39:00 | False | **5→0** | 0 | cooldown elapsed → scale-to-zero |

End-to-end: **0 → 5 → 0** in ~2 minutes, driven entirely by Redis queue depth.

## HPA (CPU + custom Prometheus metric) — CONFIGURED & ACTIVE
`HorizontalPodAutoscaler/ks-api` targets CPU 60% + `http_requests_per_second` (via
prometheus-adapter), min 2 / max 6 on the Argo Rollout. Verified present and reading metrics
(`cpu: 1%/60%`). A sustained load generator (`/api/load`) drives CPU-based scale-up; the
custom-metric path is wired through prometheus-adapter (`/apis/custom.metrics.k8s.io`).

## VPA + Goldilocks — WORKING
`VerticalPodAutoscaler` (Goldilocks-generated) provides right-sizing recommendations for the
frontend; `goldilocks-ks-api` VPA shows `PROVIDED: True` with CPU/mem recommendations.

## Gotcha captured during this demo
KEDA initially could **not** scale — its Redis scaler got `no route to host` because the
namespace's **default-deny CiliumNetworkPolicy** (correctly) blocked the `keda` namespace from
reaching Redis. Fix: an explicit ingress allow `keda ns → redis:6379`. This is the zero-trust
network policy doing exactly its job — nothing reaches Redis without an explicit rule.
