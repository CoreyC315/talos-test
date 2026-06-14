# CloudNativePG
> A Kubernetes operator that runs production HA Postgres — a robot DBA that handles failover, replication, and backups for you.

**What it is.** An **operator**: a custom controller that encodes a human DBA's expertise as software. Instead of hand-writing a [[statefulset|StatefulSet]], a Service, a failover script, and a backup cronjob, you declare one high-level object (`kind: Cluster`) saying "I want HA Postgres with 2 instances and S3 backups," and the controller continuously makes reality match. This *operator pattern* — custom resource plus a reconciling controller — is the single most important architectural idea in modern Kubernetes, and CNPG is a clean example.

**How it works.** With `instances: 2` you get one **primary** (read-write) and one **standby replica** kept current by Postgres **streaming replication**. If the primary dies, the operator promotes the replica and repoints the read-write [[service|Service]] automatically. Postgres writes every change to the **WAL** (write-ahead log) before touching data files; CNPG continuously **archives** each WAL segment to object storage and takes periodic **base backups**, which together enable **point-in-time recovery (PITR)** — restore a base backup, then replay WAL to any chosen second. It also generates an app-credentials Secret holding a ready-to-use connection URI.

**In this cluster.**
- Operator chart: `apps/workload-operators/cnpg.yaml` (sync-wave 6, ns `cnpg-system`). Database: `workloads/kubeshowcase/postgres.yaml` — `instances: 2`, `storageClass: longhorn`, WAL+base backups (gzip) to `s3://cnpg-backups/ks-db` in [[minio|MinIO]], `retentionPolicy: 7d`, plus a nightly `ScheduledBackup` (6-field cron).
- Live: `kubectl get cluster -n kubeshowcase` (expect `READY 2`, a named `PRIMARY`); three Services appear — `ks-db-rw` (primary), `ks-db-ro` (replicas), `ks-db-r` (any).

**See also:** [[statefulset]] · [[persistent-volume]] · [[longhorn]] · [[minio]] · [[redis]] · [[service]] &nbsp; **Deep dive:** [[04-storage-data]]
