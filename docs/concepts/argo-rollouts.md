# Argo Rollouts
> A drop-in replacement for the Kubernetes Deployment that adds progressive delivery — shifting traffic gradually and auto-rolling-back when metrics go bad.

**What it is.** A controller and a `Rollout` resource (same shape as a `Deployment`, but `kind: Rollout`) that ships a new version in *steps* instead of all at once. A built-in Deployment does a rolling update but has no idea whether the new pods are actually *good* — it only checks readiness probes. Argo Rollouts adds the missing judgment: it queries [[prometheus|Prometheus]] and decides whether to keep going or abort. Think of a restaurant testing a new dish on one table in three before serving it to everyone.

**How it works.** You give the `Rollout` a **strategy** (this cluster uses **canary**; see [[canary]]). The controller keeps the old ReplicaSet running, brings up a few new pods, and shifts a traffic *weight* in steps (`setWeight: 34 → pause → analysis → setWeight: 67 → …`). Without a service mesh, weight is approximated by the new-to-old pod ratio behind the [[service|Service]]. An **`AnalysisTemplate`** is a reusable health check (named Prometheus queries with pass/fail thresholds); during an `analysis` step it spawns an `AnalysisRun`, and if `failureLimit` is hit the rollout aborts and rolls back to the previous ReplicaSet.

**In this cluster.**
- Controller: `apps/workload-operators/argo-rollouts.yaml` (Helm `argo-rollouts` 2.41.0; dashboard disabled — use the `kubectl-argo-rollouts` CLI plugin).
- The `ks-api` `Rollout` + `api-health` `AnalysisTemplate`: `workloads/kubeshowcase/api.yaml` (aborts if error rate ≥ 5% or p95 latency ≥ 500ms).
- Live: `kubectl argo rollouts get rollout ks-api -n kubeshowcase`

**See also:** [[canary]] · [[prometheus]] · [[service]] · [[gitops]] · [[reloader]] &nbsp; **Deep dive:** [[08-release-ops]]
