# MinIO
> An S3-compatible object store that runs inside the cluster — a private Amazon S3 you can curl.

**What it is.** A server that speaks the **Amazon S3 API** but runs on your own hardware. Object storage is not a filesystem: instead of files in directories you have **objects** in flat **buckets**, addressed by key, written and read over HTTP, and immutable once written (you replace, not edit). Mental model: a private S3. Anything in the ecosystem that talks S3 — Postgres backups, Loki/Tempo data, Velero — can point at MinIO with zero code changes, which is why this cluster uses it as the universal backup target and data lake.

**How it works.** A single HTTP endpoint exposes the S3 API on port **9000** and a web console on **9001**; auth is S3-style access key + secret key, used via the standard S3 SDK or the `mc` CLI. Here it runs in `mode: standalone` (one replica) — fine for a homelab because [[longhorn|Longhorn]] underneath provides the real redundancy; production would run *distributed* MinIO with erasure coding so MinIO itself tolerates disk/node loss. Buckets must exist before clients can write to them.

**In this cluster.**
- Chart and config: `apps/platform/minio.yaml` (chart 5.4.0, standalone, 40Gi on `longhorn`, root creds from the `minio-root` Secret). Buckets are also re-created idempotently by an ArgoCD `PostSync` job (`platform/minio/manifests/make-buckets-job.yaml` — the chart hook didn't fire under ArgoCD). Buckets include `cnpg-backups`, `loki-chunks`, `tempo-traces`, `velero`.
- Live: `kubectl get pods,svc -n minio`; console at `http://minio.192.168.1.27.nip.io`.

**See also:** [[longhorn]] · [[cloudnative-pg]] · [[persistent-volume]] · [[velero]] · [[loki]] &nbsp; **Deep dive:** [[04-storage-data]]
(Operational gotcha — bucket creation via PostSync job, not the Helm hook: see [[OPERATIONS]].)
