# Module 4: Storage & Stateful Data — Where the Bytes Live

> Everything you've deployed so far has been *stateless* — kill the pod, a new one
> takes over, nobody notices. The moment a job stores a database row, an uploaded file,
> or a cache entry, that stops being true: that pod is now carrying data that must
> *survive* a restart, a node reboot, even a full cluster teardown. This module is how
> Kubernetes solves "where do the bytes live." After it you'll be able to provision
> persistent disks, run a self-healing HA Postgres, stand up S3-compatible object
> storage, and explain — in interview-grade detail — the difference between a Deployment
> and a StatefulSet and why it matters. "Stateful workloads on Kubernetes" is one of the
> most asked-about and least-understood areas in platform/SRE interviews; this is your
> edge.

## The big picture

Kubernetes itself stores *no* application data. It defines an **interface** — the CSI
(Container Storage Interface) — and delegates the actual disk work to a **storage
driver**. In this cluster that driver is **Longhorn**, which turns the local NVMe/SSD on
your three worker nodes into a pool of replicated, snapshot-able, backup-able block
volumes. On top of those raw volumes sit the things that actually hold your data:

- **CloudNativePG** runs a *highly-available Postgres* (a primary + a replica) — the
  source of truth for the demo app.
- **MinIO** is an *S3-compatible object store* — the bucket where everybody's backups
  and logs land.
- **Redis** is an *in-memory* cache / work queue — fast, transient, deliberately *not*
  durable.

And the durability story loops back on itself: Postgres backs up *into* MinIO, while
Longhorn's own volume backups go *off-cluster* to a Synology NAS over NFS (because MinIO
itself lives on Longhorn — you can't use a thing to back itself up).

```
                          your apps (ks-api, ks-worker, frontend)
                                |            |              |
                         Postgres (CNPG)   Redis        MinIO (S3)
                          primary+replica  (no PVC,     buckets: cnpg-backups,
                                |          emptyDir)    loki-chunks, velero, ...
                                |  WAL + base backups ----> (S3 into MinIO)
                                v
              ┌───────────────────────────────────────────────┐
              │  PVC  ──claims──▶  PV  ──provisioned by──▶ CSI  │   the K8s storage
              └───────────────────────────────────────────────┘   primitives
                                |
                         driver.longhorn.io  (the CSI driver)
                                |
        ┌─────────────┬─────────────┬─────────────┐  Longhorn keeps 2 replicas
     worker-1       worker-2       worker-3          of each volume on DISTINCT
     /var/lib/      /var/lib/      /var/lib/         nodes (survives 1 node loss)
      longhorn       longhorn       longhorn
                                |
                  daily snapshot + backup ──▶ off-cluster NFS (Synology 192.168.1.210)
```

The key mental shift for this module: **storage is a contract, not a thing.** A pod asks
for "5Gi of fast block storage that follows me around" by writing a *PersistentVolumeClaim*;
something downstream — here, Longhorn via CSI — fulfils that contract. You'll spend the
lab watching that contract get fulfilled, replicated, snapshotted, and recovered.

## Tools in this module

### Kubernetes storage primitives (PV / PVC / StorageClass / CSI) — how a pod gets a disk that outlives it

- **What it is / mental model:** Four objects that together form a supply chain for disk.
  Think of it like renting an apartment. The **StorageClass** is the *property listing*
  ("Longhorn-brand, 2-replica, expandable, delete-on-move-out"). The
  **PersistentVolumeClaim (PVC)** is your *rental application* ("I want 5Gi, read-write,
  from the longhorn class"). The **PersistentVolume (PV)** is the *actual apartment* that
  gets allocated to you. The **CSI driver** is the *property manager* that physically
  unlocks and prepares the unit. The beauty: your app (the Deployment/StatefulSet) only
  ever names the PVC. It never knows or cares which physical disk on which node backs it —
  that indirection is the whole point.
- **How it works:** A pod references a PVC by name. The PVC names a **StorageClass**.
  When the PVC is created, the StorageClass's **provisioner** (a CSI driver) dynamically
  creates a matching PV and the backing volume — this is *dynamic provisioning* (the
  alternative, hand-creating PVs, is *static* and rare). Three knobs matter constantly:
  - **Access modes:** `RWO` (ReadWriteOnce — one node at a time; what block storage like
    Longhorn gives you), `ROX` (ReadOnlyMany), `RWX` (ReadWriteMany — needs a shared
    filesystem; Longhorn can do it via an NFS sidecar but block volumes can't natively).
    *Every* volume in this cluster is `RWO`.
  - **`volumeBindingMode`:** `Immediate` (bind/provision the moment the PVC is created)
    vs `WaitForFirstConsumer` (wait until a pod is scheduled, so the volume lands near the
    pod). This cluster's `longhorn` class is `Immediate`.
  - **`reclaimPolicy`:** `Delete` (destroy the backing volume when the PVC is deleted) vs
    `Retain` (keep it — a safety net for precious data). This cluster uses `Delete`.
  - The **CSI** itself is just a gRPC spec every storage vendor implements
    (`CreateVolume`, `NodeStageVolume`, `NodePublishVolume`, …) so Kubernetes core doesn't
    need vendor-specific code. Longhorn registers as `driver.longhorn.io`.
- **In THIS cluster:** The StorageClass is created by the Longhorn Helm chart, configured
  in `apps/platform/longhorn.yaml` (`persistence.defaultClass: true`,
  `defaultClassReplicaCount: 2`). Every stateful workload requests it: see
  `workloads/kubeshowcase/postgres.yaml` line ~10 (`storageClass: longhorn`, `size: 5Gi`)
  and `apps/platform/minio.yaml` (`storageClass: longhorn`, `size: 40Gi`).
  Live:
  ```bash
  export KUBECONFIG=$PWD/terraform/.kubeconfig
  kubectl get storageclass
  kubectl get pvc -A
  kubectl get pv
  ```
  Look for `longhorn (default)` with `PROVISIONER driver.longhorn.io`,
  `VOLUMEBINDINGMODE Immediate`, `RECLAIMPOLICY Delete`. In `get pvc -A` you'll see the
  six bound claims — `minio/minio` (40Gi), two `kubeshowcase/ks-db-*` (Postgres, 5Gi
  each), `monitoring/storage-loki-0`, the Prometheus DB, and `vault/data-vault-0` — all
  `RWO`, all `STATUS Bound`. Each PVC's `VOLUME` column is the auto-generated PV name
  (`pvc-<uuid>`), the proof that dynamic provisioning fired.
- **Job relevance:** This is *the* CKA storage objective. Interviewers ask: "Walk me
  through what happens from `kubectl apply` of a PVC to a pod mounting it." "What's the
  difference between RWO and RWX, and why can't most block storage do RWX?" "A PVC is
  stuck `Pending` — how do you debug it?" (Answer: `kubectl describe pvc` → look at
  events; usually no matching StorageClass, no capacity, or `WaitForFirstConsumer` with
  no schedulable pod.) Maps to **CKA** (Storage domain, ~10%) and touches **CKAD**.
- **Learn it:**
  - kubernetes.io → Concepts → Storage → "Persistent Volumes" and "Storage Classes"
    (read both top-to-bottom; they're short and canonical).
  - kubernetes.io search: "Volume Binding Mode" and "Access Modes".
  - kubernetes-csi.github.io — the CSI developer docs ("Introduction") for the gRPC
    mechanism, if you want the layer beneath.

### Longhorn — turns local node disks into replicated, backup-able block volumes

- **What it is / mental model:** A **distributed block storage system** built *for*
  Kubernetes. Mental model: it's a software RAID-1 that spans nodes. When a pod writes to
  a Longhorn volume, Longhorn synchronously copies that write to N **replicas**, each a
  full copy living on a *different* node's local disk. Lose a node and your data is still
  on another. It's the "property manager" (CSI driver) from the previous section, plus a
  whole management layer for snapshots, backups, and rebuilds — all driven through
  Kubernetes Custom Resources you can `kubectl get`.
- **How it works:** Per volume there's one **engine** (the active controller that the pod
  talks to) and several **replicas** (the data copies). Both engine and replicas run
  *inside* an **instance-manager** pod — one per node — rather than as separate pods, to
  keep overhead low. Key concepts:
  - **Replicas:** this cluster uses **2** (`defaultReplicaCount: 2`). Longhorn's topology
    rules place them on *distinct* nodes, so a single node loss doesn't fault the volume.
    A volume's `robustness` is `healthy` (all replicas up), `degraded` (rebuilding /
    fewer than desired), or `faulted` (data unavailable).
  - **Snapshots:** crash-consistent point-in-time copies *within* the cluster (fast, but
    they die with the cluster).
  - **Backups:** snapshots exported to an external **BackupTarget** (S3 or NFS) — these
    survive a full teardown and are how you do **disaster recovery (DR)**.
  - When a replica dies, Longhorn automatically **rebuilds** a fresh one from a healthy
    replica (`concurrentReplicaRebuildPerNodeLimit: 2` caps the parallelism so a rebuild
    storm doesn't saturate disk I/O).
- **In THIS cluster:** Chart + tuning in `apps/platform/longhorn.yaml`. Note the comments
  there: replicas were bumped from a risky 1 to 2 after "Incident 5" (a single host loss
  faulting a volume). The off-cluster DR target is a Synology NAS over NFS, defined
  authoritatively in `platform/longhorn/manifests/backuptarget.yaml` — and the
  `nfsOptions=nfsvers=3,nolock,soft,timeo=300,retry=2` are load-bearing (Synology only
  exports NFSv3; `nolock` because there's no `rpc.statd` in the mount namespace). Nightly
  snapshot + backup `RecurringJob`s are in `platform/longhorn/manifests/recurring-backup.yaml`
  (`daily-snapshot` at 02:00 retain 3, `daily-backup` at 03:00 retain 7).
  Live:
  ```bash
  kubectl get volumes.longhorn.io -n longhorn-system
  kubectl get replicas.longhorn.io -n longhorn-system
  kubectl get backuptarget -n longhorn-system
  kubectl get recurringjob -n longhorn-system
  ```
  Look for: in `volumes`, the `ROBUSTNESS` column (you'll see mostly `healthy`,
  occasionally `degraded` while a replica rebuilds — that's normal and self-heals). In
  `replicas`, each `pvc-...` volume name appears on **two different `NODE`s** — that's the
  2-replica-on-distinct-hosts guarantee made concrete. In `backuptarget`, `AVAILABLE
  true` and a recent `LASTSYNCEDAT` means the off-cluster NFS DR target is reachable
  *right now*. There's also a web UI at `http://longhorn.192.168.1.27.nip.io`
  (`platform/longhorn/manifests/httproute.yaml`) — the best way to *see* volumes,
  replicas, and trigger a backup by hand.
- **Job relevance:** Longhorn specifically appears in homelab/SMB and edge-Kubernetes
  roles; the *concepts* (replication, snapshot vs backup, DR to object storage, node-loss
  behaviour) are universal and asked everywhere. Classic question: "Your stateful pod's
  node died — walk me through what happens to its data." (Replica on another node survives;
  Longhorn reattaches the volume to a new pod and rebuilds the lost replica.) Not on a
  cert directly, but it's the most tangible way to *learn* CSI/PV concepts for **CKA**.
- **Learn it:**
  - longhorn.io → Documentation → "Concepts" (engine, replica, snapshot, backup — start
    here) and "Volumes and Nodes".
  - longhorn.io search: "Setting up Disaster Recovery" and "Recurring Snapshots and
    Backups".
  - Hands-on: the Longhorn UI itself is the tutorial — click a volume, watch its replicas.

### StatefulSets vs Deployments — stable identity and storage for pods that aren't interchangeable

- **What it is / mental model:** Two controllers that both keep a set of pods running, but
  with opposite assumptions about whether the pods are *interchangeable*. A **Deployment**
  treats pods like cattle: identical, nameless (`redis-65b95dd568-mcwxw`), any one will
  do, scale them up/down in any order, they share nothing. A **StatefulSet** treats pods
  like *named pets* with assigned seats: stable ordinal names (`db-0`, `db-1`), each gets
  its *own* PVC that follows it across restarts, and they start/stop in strict order. Use
  a Deployment for stateless apps; a StatefulSet (or an operator that creates one) for
  databases, queues, and anything where "which instance am I" matters.
- **How it works:** Three things a StatefulSet gives you that a Deployment can't:
  1. **Stable network identity** — each pod gets a predictable DNS name via a *headless
     Service* (`db-0.db.ns.svc...`), so replicas can find the primary by name.
  2. **Stable, per-pod storage** — a `volumeClaimTemplate` mints one PVC *per replica*
     (`data-db-0`, `data-db-1`), and pod `db-0` always re-attaches to `data-db-0`. Scaling
     down does **not** delete the PVC (deliberate — your data is precious).
  3. **Ordered, graceful rollout** — pods come up `0,1,2…` and terminate in reverse, so a
     clustered database can elect leaders sanely instead of all restarting at once.
  Most people in production don't write raw StatefulSets for databases — they use an
  **operator** (next section) that manages StatefulSet-like behaviour for them.
- **In THIS cluster:** A clean side-by-side. `workloads/kubeshowcase/redis.yaml` is a
  **Deployment** with an `emptyDir` (ephemeral!) and the telling comment *"queue is
  transient; durability lives in Postgres."* Meanwhile Postgres
  (`workloads/kubeshowcase/postgres.yaml`) is managed by the CNPG operator, which creates
  StatefulSet-style pods each with their own Longhorn PVC. Vault, Loki, and Prometheus
  (in `get pvc -A`) are also StatefulSets — note their PVC names end in `-0`
  (`data-vault-0`, `storage-loki-0`), the StatefulSet ordinal fingerprint.
  Live:
  ```bash
  kubectl get deploy,statefulset -A | grep -Ev 'kube-system|^NAMESPACE'
  kubectl get pvc -A           # PVCs ending in -0/-1 came from a StatefulSet template
  kubectl get pod -n kubeshowcase -l app=redis -o wide   # nameless hash; emptyDir
  ```
  Look for: Deployments use a `<name>-<replicaset-hash>-<random>` pod name; StatefulSet
  pods use `<name>-<ordinal>`. The Redis pod has a random suffix and *no* PVC — kill it and
  its queue contents are gone (by design). The CNPG pods (`ks-db-2`, `ks-db-3`) each own a
  numbered Longhorn PVC.
- **Job relevance:** One of *the* most common Kubernetes interview questions: "When would
  you use a StatefulSet over a Deployment?" Be ready to name all three guarantees (stable
  identity, stable storage, ordered rollout) and to say "but in practice I'd reach for an
  operator for real databases." Also expect: "What happens to the PVC when you scale a
  StatefulSet down?" (It's retained.) Solidly **CKA** and **CKAD**.
- **Learn it:**
  - kubernetes.io → Concepts → Workloads → "StatefulSets" and "Deployments" (read both;
    the contrast is the lesson).
  - kubernetes.io tutorial: "StatefulSet Basics" (deploys a clustered app step by step).
  - kubernetes.io search: "Headless Services" — the glue that makes stable identity work.

### CloudNativePG (CNPG) — runs production HA Postgres as a Kubernetes-native operator

- **What it is / mental model:** An **operator** — a custom controller that encodes a
  human DBA's expertise as software. Instead of you writing a StatefulSet, a Service, a
  failover script, and a backup cronjob, you write *one* high-level object (`kind:
  Cluster`) that says "I want HA Postgres with 2 instances and S3 backups," and the
  operator continuously makes reality match. Mental model: it's a **robot DBA** that
  watches your Postgres 24/7 and does the standby promotion, the certificate rotation, the
  WAL archiving, and the backups so you don't get paged at 3am. The "operator pattern"
  (custom resource + controller reconciling toward desired state) is the single most
  important architectural idea in modern Kubernetes — CNPG is a gorgeous example of it.
- **How it works:**
  - **Primary/replica HA:** With `instances: 2` you get one **primary** (read-write) and
    one **standby replica** kept in sync via Postgres **streaming replication** (the
    replica continuously receives the primary's changes and replays them).
  - **Failover:** if the primary's pod/node dies, the operator promotes the healthy
    replica to primary and repoints the read-write Service — automatically. With
    `primaryUpdateStrategy: unsupervised`, it'll even do this during rolling updates
    without asking. (Tell-tale in *this* cluster: the instances are named `ks-db-2` and
    `ks-db-3`, not `-1`/`-2` — the original instance 1 was replaced during a past
    failover/reconcile. The robot did its job.)
  - **WAL (Write-Ahead Log):** Postgres writes every change to the WAL *before* touching
    the data files — it's the durable change-journal. CNPG **archives** each WAL segment
    to object storage continuously (here, gzipped to MinIO). That continuous stream + a
    periodic full **base backup** is what enables…
  - **Point-in-Time Recovery (PITR):** restore the last base backup, then replay archived
    WAL up to *any* chosen second ("recover to 14:03:00, just before the bad `DELETE`").
    CNPG uses **Barman** (`barmanObjectStore`) under the hood to manage this.
  - **App credentials:** CNPG generates a Secret (`ks-db-app`) holding a ready-to-use
    connection `uri` — the app consumes it directly (see `api.yaml`'s `DATABASE_URL`).
- **In THIS cluster:** Operator chart: `apps/workload-operators/cnpg.yaml` (Helm chart
  `cloudnative-pg` 0.28.3, sync-wave 6, namespace `cnpg-system`). The database itself:
  `workloads/kubeshowcase/postgres.yaml` — `instances: 2`, `storageClass: longhorn`,
  continuous WAL archiving + base backups to `s3://cnpg-backups/ks-db` in MinIO
  (`endpointURL: http://minio.minio.svc.cluster.local:9000`), `retentionPolicy: 7d`, plus
  a `ScheduledBackup` (`ks-db-nightly`) at 04:00 using CNPG's *6-field* cron (seconds!).
  Live:
  ```bash
  kubectl get cluster -n kubeshowcase                       # the high-level CR
  kubectl get pods -n kubeshowcase -l cnpg.io/cluster=ks-db -L cnpg.io/instanceRole
  kubectl get svc -n kubeshowcase -l cnpg.io/cluster=ks-db  # -rw / -ro / -r
  kubectl get scheduledbackup,backup -n kubeshowcase
  ```
  Look for: `get cluster` shows `INSTANCES 2  READY 2  STATUS Cluster in healthy state
  PRIMARY ks-db-3`. The `-L cnpg.io/instanceRole` column tags exactly one pod `primary`
  and one `replica`. The three Services are the operator's gift: **`ks-db-rw`** (always
  the current primary — apps write here), **`ks-db-ro`** (replicas only — offload reads),
  **`ks-db-r`** (any instance). `scheduledbackup` shows a recent `LAST BACKUP`.
- **Job relevance:** "Databases on Kubernetes" is a hot, opinionated interview topic, and
  knowing CNPG concretely is a strong signal. Expect: "Explain the operator pattern."
  "How does CNPG handle failover and how do apps avoid talking to a stale primary?"
  (Answer: the `-rw` Service is repointed to the new primary.) "What's the difference
  between a snapshot, a base backup, and WAL archiving — and which gives you PITR?"
  (Snapshot = volume-level point-in-time; base backup + continuous WAL = PITR.) The
  operator pattern is foundational for **CKAD/CKA**; CNPG itself isn't on a cert but is
  exactly the kind of system CKS-level security questions probe (it auto-issues TLS — see
  the `ks-db-server`/`ks-db-replication` Secrets).
- **Learn it:**
  - cloudnative-pg.io → Documentation → "Architecture" and "Backup and Recovery" (the
    PITR/WAL/Barman story). Read the "Cluster" CRD reference too.
  - kubernetes.io search: "Operator pattern" — the concept beneath CNPG.
  - postgresql.org docs search: "Write-Ahead Logging (WAL)" and "Continuous Archiving and
    Point-in-Time Recovery" — the Postgres-native mechanics CNPG automates.

### MinIO — S3-compatible object storage living inside the cluster

- **What it is / mental model:** A server that speaks the **Amazon S3 API** but runs on
  *your* hardware. Object storage ≠ a filesystem: instead of files in directories you have
  **objects** in flat **buckets**, addressed by key, written/read over HTTP, immutable
  once written (you replace, not edit). Mental model: it's a private Amazon S3 you can
  `curl`. Anything in the ecosystem that knows how to talk to S3 — Postgres backups,
  Loki/Tempo logs and traces, Velero cluster backups — can point at MinIO with zero code
  changes, which is exactly why this cluster uses it as the universal backup/data lake.
- **How it works:** A single HTTP endpoint (port **9000** = S3 API, port **9001** = web
  console). Authentication is S3-style **access key + secret key**. Clients use the
  standard S3 SDK or the `mc` CLI. Here it runs in `mode: standalone` (one replica) — fine
  for a homelab, where Longhorn underneath provides the actual redundancy; in production
  you'd run **distributed MinIO** (multiple nodes with erasure coding) so MinIO itself
  tolerates disk/node loss. Buckets must exist before clients write to them.
- **In THIS cluster:** Chart + config: `apps/platform/minio.yaml` (MinIO chart 5.4.0,
  `mode: standalone`, 40Gi on `longhorn`, root creds from the `minio-root` Secret). The
  buckets are declared there *and* re-created idempotently by an ArgoCD `PostSync` Job at
  `platform/minio/manifests/make-buckets-job.yaml` (the chart's own hook didn't fire under
  ArgoCD — a great real-world GitOps gotcha). Buckets: `loki-chunks`, `loki-ruler`,
  `tempo-traces`, `longhorn-backups`, `velero`, `cnpg-backups`, `pg-dumps`. Postgres
  backs up here (`postgres.yaml` → `s3://cnpg-backups/ks-db`); console is at
  `http://minio.192.168.1.27.nip.io` (`platform/minio/manifests/httproute.yaml`).
  Live:
  ```bash
  kubectl get pods,svc -n minio
  # browse buckets/objects with the mc client, inside the cluster:
  kubectl exec -n minio deploy/minio -- sh -c \
    'mc alias set m http://localhost:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" >/dev/null 2>&1; mc ls m'
  ```
  Look for: a single `Running` MinIO pod, a `Completed` `minio-make-buckets-*` pod (the
  PostSync hook), Services `minio` (9000) and `minio-console` (9001). The `mc ls` should
  list the seven buckets; `mc ls m/cnpg-backups` will show Postgres's actual backup
  objects.
- **Job relevance:** S3/object-storage literacy is assumed in every cloud/SRE role.
  Interviewers ask: "Object vs block vs file storage — when do you use each?" (Object =
  large, immutable, HTTP-addressed blobs / backups / media; block = low-latency
  databases; file = shared POSIX mounts.) "Why is `s3://` the lingua franca of backups?"
  Knowing MinIO shows you understand the S3 API independent of AWS. Not cert-specific, but
  pervasive in cloud certs and real interviews.
- **Learn it:**
  - min.io → Documentation → "MinIO Object Storage" overview, and the `mc` ("MinIO
    Client") command reference.
  - aws.amazon.com/s3 docs search: "How Amazon S3 works" (buckets/keys/objects model —
    MinIO mirrors it exactly).
  - Try the console UI at the nip.io URL above; upload a file, see it as an object.

### Redis — in-memory cache and work queue (fast, and deliberately not durable here)

- **What it is / mental model:** An **in-memory data structure store** — a server that
  keeps strings, lists, hashes, sets in RAM and answers in microseconds. Two classic jobs:
  a **cache** (stash expensive results so you don't recompute) and a **work queue** (a
  `LIST` you `LPUSH` jobs onto and workers `BRPOP` off). Mental model: a whiteboard next to
  the team — instant to read/write, shared by everyone, but wipe the board (restart the
  pod) and it's blank. In this cluster Redis is *intentionally* ephemeral; the durable
  record always lives in Postgres.
- **How it works:** Single-threaded event loop (so commands are atomic — no locks needed),
  everything in memory. Redis *can* persist (RDB snapshots / AOF append-only log), but here
  it's configured **not** to: `--save ""` disables RDB and the volume is an `emptyDir`.
  `--maxmemory 96mb --maxmemory-policy noeviction` caps RAM and makes it *reject* new
  writes rather than silently evict queued jobs (correct for a queue — you'd rather error
  than lose work). As a queue it pairs with **KEDA**, which watches the list length and
  scales the worker Deployment from zero up when jobs pile in.
- **In THIS cluster:** `workloads/kubeshowcase/redis.yaml` — a single-replica Deployment,
  `redis:7.4-alpine`, hardened (`runAsNonRoot`, `readOnlyRootFilesystem`, all caps
  dropped), `emptyDir` data volume with the comment *"queue is transient; durability lives
  in Postgres."* The app finds it via the `ks-config` ConfigMap
  (`workloads/kubeshowcase/configmap.yaml`: `REDIS_ADDR:
  redis.kubeshowcase.svc.cluster.local:6379`, `REDIS_QUEUE: jobs`). The KEDA-scaled
  consumer is `workloads/kubeshowcase/worker.yaml` (*"KEDA-scaled (Redis list length),
  scale-to-zero"*).
  Live:
  ```bash
  kubectl exec -n kubeshowcase deploy/redis -- redis-cli ping        # -> PONG
  kubectl exec -n kubeshowcase deploy/redis -- redis-cli LLEN jobs    # queue depth
  kubectl exec -n kubeshowcase deploy/redis -- redis-cli INFO memory | grep used_memory_human
  ```
  Look for: `PONG` (alive), an integer queue depth for `LLEN jobs` (0 when idle — push a
  job in the lab and watch it rise, then a KEDA-spawned worker drain it), and memory well
  under the 96mb cap.
- **Job relevance:** Redis is everywhere; expect "How would you use Redis as a cache vs a
  queue?", "What eviction policy would you pick for a cache (LRU) vs a queue (noeviction)
  — why?", and the durability trap: "Is Redis a database?" (It can be, with AOF — but
  here, deliberately, it's a transient queue; know *why* you'd choose that.) Not
  cert-specific; the *Kubernetes* lesson is the Deployment-+-emptyDir vs StatefulSet-+-PVC
  contrast — pick durability per workload, don't cargo-cult.
- **Learn it:**
  - redis.io → Documentation → "Data types" (especially Lists) and "Redis persistence"
    (to understand exactly what `--save ""` turns off).
  - redis.io search: "Using Redis as a message queue" / the `LPUSH`/`BRPOP` command pages.
  - keda.sh → "Scalers" → "Redis Lists" — how the worker autoscaling ties back to this.

## Hands-on lab (on YOUR cluster)

Run this once per shell first:

```bash
export KUBECONFIG=$PWD/terraform/.kubeconfig
```

Everything below is non-destructive or clearly reversible. Take your time and *read the
output* — the goal is to connect the YAML you studied to live behaviour.

### Lab 1 — Trace one PVC down to physical replicas on two nodes

Pick MinIO's volume and follow the storage supply chain end to end.

```bash
kubectl get pvc -n minio minio                                  # the claim
PV=$(kubectl get pvc -n minio minio -o jsonpath='{.spec.volumeName}')
echo "PV / Longhorn volume = $PV"
kubectl get pv "$PV"                                            # the provisioned PV
kubectl get volumes.longhorn.io -n longhorn-system "$PV"        # Longhorn's view
kubectl get replicas.longhorn.io -n longhorn-system -o wide \
  | grep "$PV"                                                  # the physical copies
```

**Success:** the same `pvc-<uuid>` name threads through PVC → PV → Longhorn volume, and
the final command lists the replicas on **two different `NODE`s**. You've just proven the
"5Gi RWO claim" abstraction is physically backed by 2 copies on distinct hosts.

### Lab 2 — Provision a brand-new volume and watch dynamic provisioning fire

Create a tiny throwaway PVC and a pod that mounts it; confirm Longhorn auto-creates the
backing volume; then clean up.

```bash
kubectl create namespace lab-storage 2>/dev/null
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: scratch, namespace: lab-storage}
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: longhorn
  resources: {requests: {storage: 1Gi}}
EOF
kubectl get pvc -n lab-storage scratch                 # watch it go Pending -> Bound
kubectl get volumes.longhorn.io -n longhorn-system | tail -3   # a new 1Gi volume appears
```

**Success:** within a few seconds the PVC flips to `Bound` and a fresh 1Gi
`pvc-<uuid>` appears in Longhorn — *no PV was hand-created*. Now tear it down and watch
`reclaimPolicy: Delete` reclaim the volume:

```bash
kubectl delete pvc -n lab-storage scratch
kubectl delete namespace lab-storage
kubectl get volumes.longhorn.io -n longhorn-system | tail -3   # the 1Gi volume is gone
```

### Lab 3 — See Postgres HA: who's primary, who's replica, and prove replication is live

```bash
kubectl get cluster -n kubeshowcase ks-db
kubectl get pods -n kubeshowcase -l cnpg.io/cluster=ks-db -L cnpg.io/instanceRole
PRIMARY=$(kubectl get cluster -n kubeshowcase ks-db -o jsonpath='{.status.currentPrimary}')
echo "current primary = $PRIMARY"
# Ask the primary how many standbys are streaming from it (should be 1):
kubectl exec -n kubeshowcase "$PRIMARY" -c postgres -- \
  psql -U postgres -tAc \
  "select application_name, state, sync_state from pg_stat_replication;"
```

**Success:** exactly one pod is tagged `primary`, one `replica`; the `pg_stat_replication`
query returns one row in `state=streaming` — the standby is live-tailing the primary's
WAL. *That's* HA you can point at.

### Lab 4 — Read a CNPG backup straight out of MinIO

Confirm the WAL/base-backup pipeline is actually writing to object storage.

```bash
# Was the last scheduled backup recent?
kubectl get scheduledbackup,backup -n kubeshowcase
# List the actual backup objects CNPG wrote into the MinIO bucket:
kubectl exec -n minio deploy/minio -- sh -c \
  'mc alias set m http://localhost:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" >/dev/null 2>&1; mc ls -r m/cnpg-backups/ks-db | head'
```

**Success:** `get backup` shows a `Completed` backup with a recent timestamp, and `mc ls`
lists base-backup and WAL objects under `cnpg-backups/ks-db/`. You're looking at the raw
bytes that a point-in-time recovery would replay.

### Lab 5 — Drive the Redis queue and (optionally) wake a worker

```bash
kubectl exec -n kubeshowcase deploy/redis -- redis-cli LLEN jobs        # baseline depth
# Push three fake jobs onto the queue the worker consumes:
for i in 1 2 3; do
  kubectl exec -n kubeshowcase deploy/redis -- redis-cli LPUSH jobs "lab-job-$i"
done
kubectl exec -n kubeshowcase deploy/redis -- redis-cli LLEN jobs        # now ~3
# Watch KEDA notice the backlog and scale the worker up from zero:
kubectl get deploy -n kubeshowcase ks-worker -w   # Ctrl-C after replicas rise then fall
```

**Success:** `LLEN jobs` jumps to 3, then the `ks-worker` Deployment scales from 0 to 1+
replicas, drains the queue back toward 0, and (after KEDA's cooldown) scales back to 0.
You just watched an event-driven, scale-to-zero pipeline react in real time. (If the
worker image processes only well-formed jobs and ignores `lab-job-*`, just drain manually:
`kubectl exec -n kubeshowcase deploy/redis -- redis-cli DEL jobs`.)

### Lab 6 — Browse storage in the UIs (read-only, very fast)

Open these in a browser (you're on the `192.168.1.27` LAN / VPN):

- **Longhorn UI:** `http://longhorn.192.168.1.27.nip.io` — click the *Volume* tab; pick
  any volume; you'll see its 2 replicas, their nodes, and a *Take Snapshot* / *Create
  Backup* button. Click into *Backup* to see the off-cluster NFS backups.
- **MinIO Console:** `http://minio.192.168.1.27.nip.io` — log in with the `minio-root`
  creds; browse `cnpg-backups`, `loki-chunks`, `velero` and see who's filling them.

**Success:** you can *see*, not just `kubectl get`, the replication and backup story you
read in the manifests.

## Check yourself

1. **A pod needs a disk that survives restarts. Name the four objects involved and the job
   of each.** — StorageClass (the template/listing), PVC (the request), PV (the allocated
   volume), CSI driver (provisions/mounts it).
2. **What does `volumeBindingMode: WaitForFirstConsumer` buy you over `Immediate`?** — It
   delays provisioning until a pod is scheduled, so the volume is created on/near that
   pod's node (avoids zone/node mismatches).
3. **Why can a Longhorn (block) volume be `RWO` but not `RWX` out of the box?** — Block
   storage attaches to one node at a time; `RWX` needs a shared filesystem layer (NFS/CephFS
   semantics), which block devices don't natively provide.
4. **Give the three guarantees a StatefulSet provides that a Deployment doesn't.** — Stable
   network identity (ordinal DNS name), stable per-pod storage (one PVC per replica, retained
   on scale-down), and ordered/graceful rollout.
5. **What's the difference between a Longhorn *snapshot* and a Longhorn *backup*, and why
   does this cluster send backups to NFS instead of MinIO?** — A snapshot is in-cluster
   (dies with the cluster); a backup is exported off-cluster for DR. Backups go to the
   Synology NFS because MinIO itself lives *on* Longhorn — useless for backing up Longhorn.
6. **CNPG's primary dies. What does the operator do, and how do apps avoid hitting the dead
   node?** — It promotes the in-sync replica to primary and repoints the `ks-db-rw` Service;
   apps connect to `-rw` so they automatically follow the new primary.
7. **Which two ingredients give you point-in-time recovery, and which gives you "restore to
   exactly 14:03"?** — A periodic base backup plus continuous WAL archiving; replaying the
   archived WAL up to a chosen timestamp gives the exact-second recovery.
8. **Redis here uses `emptyDir` and `--save ""`. What does that mean for durability, and
   why is it the right call?** — Data is purely in-memory and lost on pod restart; that's
   fine because Redis is only a transient work queue — the durable source of truth is
   Postgres.

## Where this fits in the path

**Before this:** the workloads/Deployments/Services basics and GitOps/ArgoCD (how these
manifests get applied) from the earlier modules. **After this:** observability
(Prometheus/Loki/Tempo — which *store* their data in the MinIO and Longhorn you just
learned) and backup/DR tooling (Velero — full-cluster backups, also landing in MinIO),
then the autoscaling module where KEDA's Redis-queue scaling gets the full treatment.
