# Argo CD
> The Kubernetes controller that implements GitOps here — it reads `Application` resources, renders the manifests they point at, and applies the diff to keep the cluster matching Git.

**What it is.** Argo CD is a controller that runs *inside* the cluster (namespace `argocd`) whose job is reconciling **Application** resources. An Application is a custom resource that says "render the manifests at *this Git path / Helm chart* and apply them to *this namespace*." Mental model: a **CI/CD robot that lives in the cluster and never sleeps** — it constantly diffs "what Git says" against "what's running" and presses Apply.

**How it works.** An Application's `spec.source(s)` says *where* the YAML comes from, `spec.destination` says *where* it goes, `spec.syncPolicy` says *how* to sync. The `repo-server` renders [[helm]] charts and [[kustomize]] overlays; the `application-controller` compares the result to the cluster and applies the diff. Two independent states: **sync** = "does the cluster match Git?" (`Synced`/`OutOfSync`); **health** = "is the workload actually working?" (`Healthy`/`Progressing`/`Degraded`). `automated` sync applies without a human; `selfHeal` reverts live drift; `prune` deletes objects whose manifest was removed from Git.

**In this cluster.**
- Root/app-of-apps app and global sync policy: `bootstrap/root-app.yaml`. Argo CD's own values (insecure server — TLS terminates at the [[gateway-api|Gateway]]; `dex.enabled: false`): `bootstrap/argocd/values.yaml`. It self-manages via `apps/platform/argocd.yaml` (with `prune: false` so it can't prune itself).
- `export KUBECONFIG=$PWD/terraform/.kubeconfig && kubectl get applications -n argocd -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status`

**See also:** [[gitops]] · [[app-of-apps]] · [[sync-waves]] · [[helm]] · [[sops]] · [[argo-rollouts]] &nbsp; **Deep dive:** [[03-gitops]]
