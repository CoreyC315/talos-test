# GitOps
> An operating model where Git holds the desired state of the whole system and an in-cluster agent continuously makes reality match it — solving config drift, manual deploys, and "who changed what?"

**What it is.** GitOps is two rules: (1) the entire desired state of your cluster is *declared* in a Git repo, and (2) an automated agent *reconciles* the live cluster to match Git. Think of it like a **thermostat**: you set the target temperature (Git) and the controller keeps acting until the room matches — you never toggle the furnace by hand. "Declarative" means you describe the destination ("Longhorn 1.12.0 should exist"), not the install steps.

**How it works.** Four principles (OpenGitOps): the system is **declarative**; desired state is **versioned and immutable** in Git (history = audit log, `git revert` = rollback); changes are **pulled** by an agent running *inside* the cluster (no cluster credentials in CI — more secure than push); and the system is **continuously reconciled**, so hand-edits to live objects are detected as drift and corrected. The payoff is reproducibility, auditability, and easy rollback.

**In this cluster.**
- The whole repo *is* GitOps. Single entry point: `bootstrap/root-app.yaml`; after one imperative bootstrap (`bootstrap/02-bootstrap-argocd.sh`), Git drives everything. The cluster can be rebuilt from Git per `docs/REBUILD.md`.
- `export KUBECONFIG=$PWD/terraform/.kubeconfig && kubectl get applications -n argocd` — every running app maps to a file under `apps/`, almost all `Synced / Healthy`.

**See also:** [[argo-cd]] · [[app-of-apps]] · [[helm]] · [[kustomize]] · [[sops]] · [[terraform]] &nbsp; **Deep dive:** [[03-gitops]]
