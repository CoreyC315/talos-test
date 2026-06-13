# DR drill — Velero backup / restore of the app namespace

**Hypothesis:** the entire `kubeshowcase` namespace (incl. CNPG Postgres data via CSI
snapshot data-movement to MinIO) can be deleted and restored with data intact.

## Pre-checks
```bash
export KUBECONFIG=talos/clusterconfig/kubeconfig
velero version          # client+server
velero backup-location get   # "default" -> MinIO bucket "velero", Available
# seed identifiable data:
curl -sk -X POST https://app.192.168.1.27.nip.io/api/items -d '{"name":"dr-canary-PRE"}' -H 'content-type: application/json'
curl -sk https://app.192.168.1.27.nip.io/api/items | grep dr-canary   # confirm present
```

## Backup
```bash
velero backup create ks-dr-$(date +%H%M) --include-namespaces kubeshowcase --wait
velero backup describe --details $(velero backup get -o name | head -1)
# confirm objects landed in MinIO:
#   mc ls m/velero/backups/
```

## Destroy
```bash
kubectl delete namespace kubeshowcase --wait=false
# watch it go:
kubectl get ns kubeshowcase -w   # Terminating -> gone
```

## Restore
```bash
BK=$(velero backup get -o name | head -1 | cut -d/ -f2)
velero restore create --from-backup "$BK" --wait
kubectl -n kubeshowcase get pods -w           # CNPG bootstraps from restored PVC data
```

## Verify
```bash
# CNPG cluster healthy + the canary row survived:
kubectl -n kubeshowcase get cluster ks-db
curl -sk https://app.192.168.1.27.nip.io/api/items | grep dr-canary-PRE   # MUST be present
```

## Extra credit — CNPG PITR
CNPG also continuously archives WAL to `s3://cnpg-backups`. For point-in-time recovery, bootstrap
a new Cluster with `recovery.recoveryTarget.targetTime`, independent of Velero. See
`workloads/kubeshowcase/postgres.yaml` (barmanObjectStore).

## Record
- Backup size + duration; restore duration
- Data integrity: canary row present? CNPG instances back to 2/2?
- RTO (delete → serving again), RPO (≈ last WAL archive, seconds)
