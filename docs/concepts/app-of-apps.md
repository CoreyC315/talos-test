# App-of-Apps
> A bootstrap pattern where one Argo CD `Application` points at a directory of *other* Application manifests — so a single command fans out into your whole platform, and `git push` installs new software.

**What it is.** Instead of registering ~30 apps by hand, you create one **root** Application whose source is a *directory full of Application manifests*. Argo CD syncs the root, which creates one child Application per file it finds. Mental model: a **table of contents that builds the rest of the book** — point Argo CD at the index and it assembles everything else.

**How it works.** The root Application sets `path: apps` with `directory.recurse: true`, so it scans every subfolder of `apps/` and treats each YAML as a child Application to create and manage. Adding software = adding one file + `git push`; the root notices the new manifest and spawns its app. A `resources-finalizer.argocd.argoproj.io` finalizer on the root ensures a clean cascading delete of all children if the root is removed.

**In this cluster.**
- The root lives in `bootstrap/root-app.yaml` (`path: apps`, `recurse: true`, finalizer). Child manifests are organized under `apps/platform/`, `apps/observability/`, etc. (e.g. `apps/platform/longhorn.yaml`).
- `export KUBECONFIG=$PWD/terraform/.kubeconfig && kubectl get application root -n argocd -o jsonpath='{.spec.source.path}  recurse={.spec.source.directory.recurse}{"\n"}'`

**See also:** [[argo-cd]] · [[gitops]] · [[sync-waves]] · [[helm]] &nbsp; **Deep dive:** [[03-gitops]]
