# Velero
> A backup/restore tool that snapshots a namespace's Kubernetes objects *and* its persistent volume data to S3-compatible storage — your "I deleted the app / corrupted its data" undo.

**What it is.** Velero is Time Machine for a namespace: it captures the API objects plus the actual bytes in the volumes, so you can recreate an app and its data after a deletion or corruption. It covers a different layer than an **etcd snapshot** (the whole cluster's brain, for rebuilding the control plane): you want both. Here Velero is the app-level layer of a three-tier DR strategy.

**How it works.** Velero runs a server plus a per-node **node-agent**. `velero backup create` snapshots the API objects in a namespace and, with **CSI data movement** (`features: EnableCSI`, `defaultSnapshotMoveData: true`), copies the actual [[persistent-volume|PV]] bytes — via [[csi|CSI]]/[[longhorn|Longhorn]] — into object storage. Restore re-creates the objects and re-hydrates the volumes. The storage target here is in-cluster [[minio|MinIO]] (an S3 server) via the AWS plugin pointed at `s3Url: http://minio.minio.svc...`.

**In this cluster.**
- Velero App (Helm `velero` 12.0.2 + AWS plugin v1.13.0; backup location `default` → MinIO bucket `velero`; node-agent enabled): `apps/platform/velero.yaml`.
- DR drill runbook (backup → delete namespace → restore → verify [[cloudnative-pg|CNPG]] data survived): `load-and-chaos/runbooks/dr-velero.md`.
- Live: `velero backup-location get` (`default` should read `Available`)

**See also:** [[minio]] · [[persistent-volume]] · [[csi]] · [[longhorn]] · [[cloudnative-pg]] · [[etcd]] &nbsp; **Deep dive:** [[08-release-ops]]
