# Sync Waves
> An Argo CD ordering mechanism — an annotation that groups resources into numbered waves so dependencies converge before the things that need them.

**What it is.** A sync wave is a number you stamp on a resource via the annotation `argocd.argoproj.io/sync-wave: "N"`. Argo CD applies all wave-0 resources first, waits for them to become Healthy, then wave 1, and so on. Mental model: **boarding a plane by group number** — first class before economy, so the aisle isn't blocked. It encodes "X must exist before Y."

**How it works.** During a sync, Argo CD sorts resources by wave (lowest first; default 0; negatives allowed) and processes one wave at a time, only advancing once the current wave's resources report Healthy. This lets you express real dependencies declaratively without scripting an install order. In this repo waves run roughly: [[cilium]] (network) wave **0**, storage/[[cert-manager]] wave **2**, the [[gateway-api|Gateway]] wave **3**, [[observability-pillars|observability]] wave **4**, security **5**, operators **6**, the demo app **7**.

**In this cluster.**
- Every file under `apps/` carries the annotation (e.g. `apps/platform/longhorn.yaml` is `"2"`, `apps/observability/kube-prometheus-stack.yaml` is `"4"`). Wave 0 must be first because nothing has a network until the [[cni|CNI]] is up.
- `export KUBECONFIG=$PWD/terraform/.kubeconfig && kubectl get applications -n argocd -o custom-columns=NAME:.metadata.name,WAVE:'.metadata.annotations.argocd\.argoproj\.io/sync-wave',HEALTH:.status.health.status | sort -k2`

**Gotcha.** If one app in a wave never goes Healthy, the root app stalls "waiting for healthy state of X" and *every later wave is blocked* — find and fix the gating app. See [[OPERATIONS]].

**See also:** [[argo-cd]] · [[app-of-apps]] · [[gitops]] · [[cilium]] · [[gateway-api]] &nbsp; **Deep dive:** [[03-gitops]]
