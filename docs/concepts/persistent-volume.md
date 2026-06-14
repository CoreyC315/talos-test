# PersistentVolume & PVC
> The Kubernetes contract that gives a pod a disk which outlives it — a claim that something downstream must fulfil.

**What it is.** Storage in Kubernetes is a supply chain of objects, not a thing. The **StorageClass** is the property listing ("Longhorn-brand, 2-replica, delete-on-move-out"), the **PersistentVolumeClaim (PVC)** is your rental application ("I want 5Gi, read-write"), and the **PersistentVolume (PV)** is the actual apartment you get. Your app only ever names the PVC — it never knows which physical disk on which node backs it.

**How it works.** A pod references a PVC by name; the PVC names a StorageClass whose **provisioner** (a [[csi]] driver) dynamically creates a matching PV and backing volume — *dynamic provisioning*. Three knobs matter: **access mode** (`RWO` = one node at a time, what block storage gives; `RWX` needs a shared filesystem), **`volumeBindingMode`** (`Immediate` vs `WaitForFirstConsumer`), and **`reclaimPolicy`** (`Delete` vs `Retain`). Every volume in this cluster is `RWO`, `Immediate`, `Delete`. A `Pending` PVC almost always means no matching StorageClass, no capacity, or an unschedulable consumer.

**In this cluster.**
- The `longhorn` StorageClass (default, 2 replicas) comes from `apps/platform/longhorn.yaml`; claims are made in `workloads/kubeshowcase/postgres.yaml` (`storageClass: longhorn`, 5Gi) and `apps/platform/minio.yaml` (40Gi).
- Live: `kubectl get storageclass; kubectl get pvc -A; kubectl get pv` — look for `longhorn (default)`, provisioner `driver.longhorn.io`, every claim `Bound` and `RWO`.

**See also:** [[csi]] · [[longhorn]] · [[statefulset]] · [[cloudnative-pg]] &nbsp; **Deep dive:** [[04-storage-data]]
