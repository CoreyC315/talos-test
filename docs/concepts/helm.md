# Helm
> The package manager for Kubernetes — it bundles the dozens of objects a real app needs into a templated **chart** with a single **values** knobs-file, so installing software isn't hand-writing YAML.

**What it is.** A real piece of software (Prometheus, Longhorn) is dozens of Kubernetes objects — Deployments, Services, ConfigMaps, RBAC, CRDs. Helm packages them into a templated bundle called a **chart**, configured by one `values.yaml` you override. Mental model: Helm is **`apt`/`brew` for Kubernetes** — `helm install prometheus` is like `apt install nginx`, and values are the config you tweak instead of editing package internals.

**How it works.** A chart = Go-templated YAML + a default `values.yaml` + metadata. At render time Helm substitutes your values into the templates and emits plain Kubernetes manifests (`helm template` shows exactly this). Charts live in **repositories** (HTTP index files or OCI registries); you pin a **chart version** (`targetRevision`) for reproducibility. Crucially, **[[argo-cd|Argo CD]] renders Helm itself** — it runs `helm template` and applies the result, so there's no in-cluster release state (no Tiller).

**In this cluster.**
- Most apps are a Helm source inside an Argo CD Application. Inline values via `valuesObject`: `apps/platform/longhorn.yaml` (chart `longhorn` v1.12.0 from `https://charts.longhorn.io`). External values via a multi-source `$values` ref: `apps/platform/argocd.yaml` pulls `bootstrap/argocd/values.yaml`.
- `export KUBECONFIG=$PWD/terraform/.kubeconfig && kubectl get application longhorn -n argocd -o jsonpath='{range .spec.sources[*]}{.chart}{" "}{.targetRevision}{" "}{.repoURL}{"\n"}{end}'`

**See also:** [[kustomize]] · [[argo-cd]] · [[gitops]] · [[longhorn]] · [[prometheus]] &nbsp; **Deep dive:** [[03-gitops]]
