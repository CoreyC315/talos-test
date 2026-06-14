# Redis
> An in-memory data store used here as a fast work queue — deliberately ephemeral, because durability lives in Postgres.

**What it is.** An **in-memory data structure store** — a server that keeps strings, lists, hashes, and sets in RAM and answers in microseconds. Two classic jobs: a **cache** (stash expensive results) and a **work queue** (a `LIST` you `LPUSH` jobs onto and workers `BRPOP` off). Mental model: a whiteboard next to the team — instant and shared, but wipe it (restart the pod) and it's blank. In this cluster Redis is *intentionally* ephemeral; the durable record always lives in [[cloudnative-pg|Postgres]].

**How it works.** A single-threaded event loop makes commands atomic with no locks, with everything held in memory. Redis *can* persist (RDB snapshots / AOF log), but here it's configured **not** to: `--save ""` disables RDB and the data volume is an `emptyDir`. `--maxmemory 96mb --maxmemory-policy noeviction` caps RAM and makes it *reject* new writes rather than silently drop queued jobs — the right choice for a queue. As a queue it pairs with [[keda|KEDA]], which watches the list length and scales the worker [[statefulset|Deployment]] from zero.

**In this cluster.**
- `workloads/kubeshowcase/redis.yaml` — single-replica Deployment, `redis:7.4-alpine`, hardened (non-root, read-only rootfs, all caps dropped), `emptyDir` data ("queue is transient; durability lives in Postgres"). The app finds it via `workloads/kubeshowcase/configmap.yaml` (`REDIS_ADDR`, `REDIS_QUEUE: jobs`); the consumer is `workloads/kubeshowcase/worker.yaml`.
- Live: `kubectl exec -n kubeshowcase deploy/redis -- redis-cli ping` (→ `PONG`); `redis-cli LLEN jobs` shows queue depth.

**See also:** [[cloudnative-pg]] · [[statefulset]] · [[keda]] · [[persistent-volume]] · [[service]] &nbsp; **Deep dive:** [[04-storage-data]]
