# StatefulSet
> A workload controller for pods that aren't interchangeable — giving each a stable name and its own disk that follows it.

**What it is.** A controller that keeps a set of pods running, but treats them as *named pets with assigned seats* rather than interchangeable cattle. A Deployment gives you nameless, identical pods (`redis-65b95dd568-mcwxw`) that share nothing; a StatefulSet gives ordinal names (`db-0`, `db-1`), each with its own [[persistent-volume|PVC]] that re-attaches across restarts. Use a Deployment for stateless apps, a StatefulSet (or an operator that creates one) for databases, queues, and anything where "which instance am I" matters.

**How it works.** A StatefulSet provides three things a Deployment can't: (1) **stable network identity** — each pod gets a predictable DNS name via a headless [[service|Service]] (`db-0.db.ns.svc...`); (2) **stable per-pod storage** — a `volumeClaimTemplate` mints one PVC per replica (`data-db-0`), and scaling down deliberately does *not* delete it; (3) **ordered rollout** — pods come up `0,1,2…` and terminate in reverse, so a clustered database can elect leaders sanely. In production you usually let an operator manage this rather than writing raw StatefulSets.

**In this cluster.**
- A clean contrast: `workloads/kubeshowcase/redis.yaml` is a Deployment with `emptyDir` (ephemeral by design), while [[cloudnative-pg|CNPG]] (`workloads/kubeshowcase/postgres.yaml`), Vault, and Loki run StatefulSet-style pods — note PVC names ending in `-0` (`data-vault-0`, `storage-loki-0`), the ordinal fingerprint.
- Live: `kubectl get deploy,statefulset -A`; PVCs ending in `-0`/`-1` came from a StatefulSet template.

**See also:** [[persistent-volume]] · [[cloudnative-pg]] · [[redis]] · [[service]] · [[longhorn]] &nbsp; **Deep dive:** [[04-storage-data]]
