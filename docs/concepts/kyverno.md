# Kyverno
> A Kubernetes-native policy engine that validates, mutates, or generates objects at admission — policy-as-code in plain YAML.

**What it is.** Kyverno is a policy engine running as an **admission webhook**: when an object is submitted, the API server asks Kyverno "is this allowed, and do you want to change it?" Mental model: a programmable bouncer whose rules you write in plain YAML (no Rego to learn, unlike OPA/Gatekeeper). Where [[pod-security-standards]] give three fixed dress codes, Kyverno lets you write arbitrary rules. It can **validate** (allow/block/audit), **mutate** (auto-edit, e.g. add a label), and **generate** (create related objects, e.g. a default NetworkPolicy per namespace).

**How it works.** A `ClusterPolicy` holds `rules`, each with a `match`/`exclude` plus a `validate`/`mutate`/`generate` block. Validation uses a pattern language with wildcards, anchors like `=()` ("if this key exists it must match"), and `anyPattern` (OR). The key knob is `validationFailureAction`: **`Audit`** records a violation in a PolicyReport but admits the object; **`Enforce`** rejects it. A background controller re-evaluates *existing* resources too.

**In this cluster.**
- Helm app `apps/security/kyverno.yaml` (wave 5); the webhook is deliberately **fail-open** (`forceFailurePolicyIgnore`), which is only safe because every policy is `Audit`, not `Enforce`. Five policies in `security/kyverno/policies/`: disallow-latest-tag, require-non-root, require-probes, require-resources, restrict-registries (all `exclude` infra namespaces).
- Inspect: `kubectl get cpol` and `kubectl get policyreport -A | awk '$5>0 || $6>0'`

**See also:** [[pod-security-standards]] · [[rbac]] · [[trivy]] · [[gitops]] · [[requests-and-limits]] &nbsp; **Deep dive:** [[07-security-governance]]
