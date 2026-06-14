# Reloader
> A tiny controller that restarts pods automatically when their ConfigMap or Secret changes — closing a famous Kubernetes gap.

**What it is.** Kubernetes has a footgun: if you change a ConfigMap or Secret, **pods do not restart to pick it up** — env vars and `envFrom` values are baked in at container start time. Reloader watches your config objects and triggers a rolling restart of any workload annotated to care. Analogy: a smoke detector wired to the doorbell — when the config "changes," it nudges the right rooms to wake up. Without it you're running manual `kubectl rollout restart` and hoping you didn't forget one.

**How it works.** Reloader watches ConfigMaps/Secrets cluster-wide. Any Deployment / `Rollout` / [[statefulset|StatefulSet]] / DaemonSet carrying `reloader.stakater.com/auto: "true"` (auto-detect every config it references) — or a targeted `configmap.reloader.stakater.com/reload: <name>` — gets restarted: Reloader bumps a pod-template annotation, which the workload controller treats as a change → rolling update. It cooperates with [[argo-rollouts|Argo Rollouts]]: a reload on a `Rollout` runs through the [[canary]] steps, not a blind restart.

**In this cluster.**
- Controller (Helm `reloader` 2.2.12): `apps/workload-operators/reloader.yaml`.
- `ks-api` and `ks-worker` carry `reloader.stakater.com/auto: "true"`: `workloads/kubeshowcase/api.yaml`, `workloads/kubeshowcase/worker.yaml` (roll when `ks-config` / `ks-sops-demo` change).
- Live: `kubectl -n reloader logs deploy/reloader-reloader | tail -20`

**See also:** [[argo-rollouts]] · [[canary]] · [[cert-manager]] · [[external-secrets]] · [[sops]] &nbsp; **Deep dive:** [[08-release-ops]]
