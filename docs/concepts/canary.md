# Canary Deployment
> A release strategy that shifts a small, growing slice of traffic to a new version and rolls back automatically if it misbehaves — named after the canary in a coal mine.

**What it is.** A way to deploy a risky change without a big-bang outage. You expose the new version to a *fraction* of users first (the "canary"), watch it, and only widen the rollout if it stays healthy. The opposite of a canary is **blue-green**, where you bring up a *full* second copy and flip 100% of traffic at once with the old copy kept warm for instant rollback. Canary = gradual; blue-green = instant cutover.

**How it works.** Keep the old version running, bring up new pods, and shift a traffic *weight* to them in steps (e.g. 34% → pause → analyze → 67% → pause → analyze → 100%). Between steps a metric **analysis** queries [[prometheus|Prometheus]] for error rate and latency; if a threshold is breached, traffic snaps back to the old version. With no service mesh in this cluster, the weight is approximated by the ratio of new-to-old pods behind the [[service|Service]]. [[argo-rollouts|Argo Rollouts]] is the controller that drives this dance here.

**In this cluster.**
- The `ks-api` `Rollout` uses canary steps `setWeight: 34 → pause 60s → analysis → setWeight: 67 → pause 60s → analysis`: `workloads/kubeshowcase/api.yaml`.
- The `api-health` `AnalysisTemplate` (same file) aborts the canary if 5xx rate ≥ 5% or p95 latency ≥ 500ms.
- Live: `kubectl argo rollouts get rollout ks-api -n kubeshowcase --watch`

**See also:** [[argo-rollouts]] · [[prometheus]] · [[service]] · [[gateway-api]] · [[reloader]] &nbsp; **Deep dive:** [[08-release-ops]]
