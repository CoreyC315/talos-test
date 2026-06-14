# Pod Security Standards
> Kubernetes' built-in, label-driven gate that decides how privileged a pod is allowed to be in each namespace.

**What it is.** Pod Security Standards (PSS) are three predefined profiles — **privileged** (anything goes), **baseline** (block well-known dangers like host networking and most host paths), and **restricted** (lock down hard: non-root, drop ALL capabilities, seccomp, no host namespaces). The **Pod Security Admission** controller is the built-in engine that enforces them (it replaced the old PodSecurityPolicy). Think of it as a dress code enforced at the door of each namespace: you post the code, the bouncer checks every pod.

**How it works.** You don't write rules — you **label a namespace** with up to three modes: `pod-security.kubernetes.io/enforce` (reject violators), `/audit` (allow but log), and `/warn` (allow but warn at apply), each set to a level. Enforcement happens at admission: a pod violating `restricted` is simply refused before it ever runs. It's coarse, built-in, and free — the floor that [[kyverno]] builds on for arbitrary custom rules.

**In this cluster.**
- Posture documented in `security/pss/namespaces.md`; `kubeshowcase` enforces `restricted`, while `falco`/`kube-bench`/`longhorn-system`/`spegel`/`kube-system` get an explicit `privileged` exception for a concrete reason. [[argo-cd]] applies labels via `managedNamespaceMetadata` (e.g. `apps/security/falco.yaml`, `apps/security/kube-bench.yaml`).
- See the whole posture: `kubectl get ns -o custom-columns='NAME:.metadata.name,ENFORCE:.metadata.labels.pod-security\.kubernetes\.io/enforce'`

**See also:** [[rbac]] · [[kyverno]] · [[falco]] · [[kube-bench]] &nbsp; **Deep dive:** [[07-security-governance]]
