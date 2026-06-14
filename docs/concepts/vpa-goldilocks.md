# VPA & Goldilocks
> Right-sizing requests/limits (how *big* each pod is) instead of how *many* — plus a dashboard of recommendations.

**What it is.** [[hpa|HPA]] changes how many pods; the **Vertical Pod Autoscaler (VPA)** changes how big each pod is, observing real CPU/memory usage and recommending (or applying) better requests/limits. **Goldilocks** runs a VPA in recommend-only mode for every workload in opted-in namespaces and shows the suggested numbers in a dashboard. Analogy: VPA is a tailor who re-cuts the suit; Goldilocks is the fitting-room mirror showing what size you *should* wear.

**How it works.** VPA has three parts — **recommender** (computes targets from usage history), **updater** (evicts pods whose requests are too far off so they reschedule), and **admission controller** (a mutating webhook injecting recommended requests at pod creation). `updateMode`: `Off` (recommend only — what Goldilocks uses), `Initial`, `Auto`/`Recreate`. **Critical rule:** never point a VPA and an HPA at the *same* CPU/memory signal — they fight (VPA raises requests → changes CPU% → moves the HPA). That's why this repo splits them across workloads. See [[OPERATIONS]].

**In this cluster.**
- Operators via [[argo-cd|Argo CD]]: `apps/workload-operators/vpa-goldilocks.yaml` (Fairwinds `vpa 4.7.2` + `goldilocks 10.4.0`, sync-wave `6`). Goldilocks is enabled on `kubeshowcase` by the label `goldilocks.fairwinds.com/enabled: "true"` in `workloads/kubeshowcase/namespace.yaml`.
- The active VPA targets `ks-frontend` (`workloads/kubeshowcase/autoscaling.yaml`, `updateMode: Auto`, bounded `minAllowed`/`maxAllowed`); `ks-frontend` is deliberately **not** HPA-managed.
- Live: `kubectl get vpa -n kubeshowcase` (`ks-frontend` is `Auto`; `goldilocks-*` are `Off`/recommend).

**See also:** [[hpa]] · [[keda]] · [[requests-and-limits]] · [[metrics-server]] · [[scheduling-constraints]] &nbsp; **Deep dive:** [[05-scaling-scheduling]]
