# Longhorn
> Distributed block storage that turns the local disks on your worker nodes into replicated, snapshot-able, backup-able volumes.

**What it is.** A distributed block storage system built for Kubernetes. Mental model: software RAID-1 that spans nodes. When a pod writes to a Longhorn volume, the write is synchronously copied to N **replicas**, each a full copy on a *different* node's local disk — lose a node and your data is still elsewhere. It is this cluster's only [[csi]] driver, plus a management layer for snapshots, backups, and rebuilds, all exposed as Kubernetes custom resources.

**How it works.** Per volume there is one **engine** (the active controller the pod talks to) and several **replicas** (the data copies), all hosted inside one **instance-manager** pod per node. This cluster runs **2 replicas** placed on distinct nodes by topology rules, so a single host loss keeps a volume `healthy` rather than `faulted`. **Snapshots** are fast in-cluster point-in-time copies that die with the cluster; **backups** are exported to an external target for disaster recovery. A dead replica is automatically **rebuilt** from a healthy one.

**In this cluster.**
- Chart and tuning in `apps/platform/longhorn.yaml` (replicas bumped 1→2 after "Incident 5"); backups go *off-cluster* to a Synology NAS over NFS (`platform/longhorn/manifests/backuptarget.yaml`) because [[minio]] itself lives on Longhorn. Nightly jobs in `platform/longhorn/manifests/recurring-backup.yaml`.
- Live: `kubectl get volumes.longhorn.io -n longhorn-system` (watch the `ROBUSTNESS` column); `kubectl get backuptarget -n longhorn-system` (`AVAILABLE true` = DR reachable). UI at `http://longhorn.192.168.1.27.nip.io`.

**See also:** [[csi]] · [[persistent-volume]] · [[statefulset]] · [[minio]] · [[velero]] &nbsp; **Deep dive:** [[04-storage-data]]
(Operational gotcha — the pre-upgrade-checker hook and NFS DR options bite: see [[OPERATIONS]].)
