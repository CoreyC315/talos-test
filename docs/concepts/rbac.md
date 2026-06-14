# RBAC
> Role-Based Access Control — Kubernetes' default-deny system deciding which subject may perform which verb on which resource.

**What it is.** Everything in Kubernetes is an API call, and RBAC decides whether a **subject** (user, group, or **ServiceAccount**) may perform a **verb** (get/list/create/delete…) on a **resource** (pods, secrets…). Mental model: a building access-card system. A **Role** is a key for certain doors on one floor (namespace); a **ClusterRole** opens doors building-wide. A **RoleBinding**/**ClusterRoleBinding** hands that key to a person or robot. No binding means no access — RBAC is default-deny.

**How it works.** Two halves: a `Role`/`ClusterRole` lists `rules` (apiGroups, resources, optional `resourceNames`, verbs); a binding connects that role to `subjects`. Permissions are purely **additive** — there are no deny rules, so least privilege means granting the smallest set possible. ServiceAccounts are the identities your *pods* use: if a pod mounts its token, the app can call the API with whatever that SA is bound to.

**In this cluster.**
- `workloads/kubeshowcase/rbac.yaml` is a least-privilege exhibit: the `ks-api` ServiceAccount sets `automountServiceAccountToken: false` (no token at all), and `Role` `ks-api-config-reader` grants only `get`/`watch` on the single ConfigMap `ks-config`.
- Test access: `kubectl auth can-i get configmaps -n kubeshowcase --as=system:serviceaccount:kubeshowcase:ks-api` (yes) vs `delete pods` (no).

**See also:** [[pod-security-standards]] · [[kyverno]] · [[vault]] · [[external-secrets]] &nbsp; **Deep dive:** [[07-security-governance]]
