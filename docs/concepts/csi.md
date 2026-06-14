# CSI
> The vendor-neutral gRPC interface that lets any storage system plug into Kubernetes without core code changes.

**What it is.** The **Container Storage Interface (CSI)** is a standard contract — a set of gRPC calls — that every storage vendor implements so Kubernetes core doesn't need vendor-specific code. Think of it as the "property manager" in the storage supply chain: the [[persistent-volume|PVC]] is the rental application, the PV is the apartment, and the CSI driver is who physically unlocks and prepares the unit. Decoupling storage from the kubelet is the whole point.

**How it works.** A CSI driver registers itself under a name (here `driver.longhorn.io`) and answers calls like `CreateVolume`, `DeleteVolume`, `NodeStageVolume`, and `NodePublishVolume`. When a PVC's StorageClass points at that provisioner, Kubernetes invokes the driver to create the backing volume, attach it to the node, and mount it into the pod's filesystem. The same spec covers snapshots and volume expansion, so features arrive uniformly across vendors.

**In this cluster.**
- The only CSI driver here is [[longhorn]], installed via `apps/platform/longhorn.yaml`; it registers as `driver.longhorn.io`.
- Live: `kubectl get csidrivers` — you'll see `driver.longhorn.io`; `kubectl get storageclass -o wide` shows it as the provisioner backing the `longhorn` class.

**See also:** [[persistent-volume]] · [[longhorn]] · [[statefulset]] · [[helm]] &nbsp; **Deep dive:** [[04-storage-data]]
