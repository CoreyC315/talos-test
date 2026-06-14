# Kustomize
> A template-free way to compose and patch plain Kubernetes YAML — keep manifests as valid YAML and lay *overlays* on top, instead of filling in `{{ }}` placeholders.

**What it is.** Where [[helm|Helm]] templates YAML with `{{ }}` placeholders, Kustomize keeps your YAML *as plain valid YAML* and applies overlays (patches) on top. Mental model: Helm is a **fill-in-the-blanks form**; Kustomize is **tracing paper** — you lay a patch over a base and change only the bits you mark. It's built into `kubectl` (`kubectl apply -k`).

**How it works.** A `kustomization.yaml` lists `resources` (plain YAML to include), `patches` (strategic-merge or JSON-6902 edits), transformers (a common `namespace`, name prefixes, labels, image tags), and **generators** — including plugins. `kustomize build <dir>` emits the final combined YAML. Here [[argo-cd|Argo CD]] runs Kustomize for the *self-managed* portion of each app — the Git source pointing at a `manifests/` directory.

**In this cluster.**
- Most apps pair a Helm chart with their own Kustomize dir (multi-source). E.g. `apps/platform/longhorn.yaml` source 2 = `platform/longhorn/manifests`; its `kustomization.yaml` sets `namespace: longhorn-system`, lists `httproute.yaml`/`recurring-backup.yaml`/`backuptarget.yaml`, and a [[sops|KSOPS]] generator. Plugins are enabled via `kustomize.buildOptions: --enable-alpha-plugins --enable-exec` in `bootstrap/argocd/values.yaml`.
- `kustomize build platform/longhorn/manifests --enable-alpha-plugins --enable-exec 2>&1 | head -40` (decryption may fail locally without the age key — the namespace/resources still render).

**See also:** [[helm]] · [[sops]] · [[argo-cd]] · [[gitops]] · [[longhorn]] &nbsp; **Deep dive:** [[03-gitops]]
