# REBUILD — bring KubeShowcase back, from nothing or from a backup

The authoritative runbook for "deploy this again" and "restore it as it was." Three scenarios:
**A) fresh rebuild**, **B) adopt the existing cluster into Terraform**, **C) data restore**.

The layering that makes this work:

| Layer | Owned by | Reproduced by |
|---|---|---|
| Proxmox VMs + Talos OS | infra | `terraform apply` |
| Cilium (CNI), Gateway-API CRDs | bootstrap | `terraform apply` (helm_release + the shared `bootstrap/00` prep) |
| Argo CD + root app-of-apps | bootstrap | `terraform apply` |
| All 5 tiers + the app config | GitOps | **Argo CD**, from this repo |
| App container images | build | `./bootstrap/03-finish.sh` (builds from `app-src/`) |
| Vault init/unseal + ESO | one-time | `./bootstrap/03-finish.sh` |
| Volume **data** (Postgres rows, etc.) | stateful | restore from the Synology (scenario C) |

Prereqs on the workstation: `terraform`, `kubectl`, `helm`, `talosctl`, `docker`, and the SOPS
**age key** at `~/.config/sops/age/keys.txt` (restore it from a time capsule on a new machine —
see C). The Proxmox API token in `terraform/terraform.tfvars`.

---

## A. Fresh rebuild (clean slate → fully running)
```bash
git clone https://github.com/CoreyC315/talos-test.git && cd talos-test

cd terraform
cp terraform.tfvars.example terraform.tfvars      # add the Proxmox API token
terraform init
terraform apply                                    # ISOs → 6 VMs → Talos → Cilium → Argo CD → root app
cd ..

export KUBECONFIG=$PWD/talos/clusterconfig/kubeconfig   # written by terraform
kubectl -n argocd get applications -w              # wait ~10 min for the fleet to go green

./bootstrap/03-finish.sh                           # build+push app images, init+seed Vault
curl -sk https://app.192.168.1.27.nip.io/api/stats # smoke test
```
That's the whole platform back. `terraform destroy && terraform apply` repeats it. The only
prompts are: Proxmox token (once, in tfvars) and the Vault root token printed by the finish step
(save it). Everything else is Git + Argo CD.

> Why a finish step at all? Two things Argo CD structurally can't do: (1) the app *images* are
> built from `app-src/` and pushed to the in-cluster registry (no `write:packages` token for
> ghcr.io), and (2) Vault's first-time init/unseal is deliberately manual (the root token is
> yours, never in Git).

---

## B. Adopt the EXISTING hand-built cluster into Terraform (no rebuild)
The live cluster was created by hand, so it isn't in Terraform state. To manage its VMs via
Terraform in place (e.g. resize) without disturbing the running Talos/Cilium/Argo CD:
```bash
cd terraform
terraform init
./import.sh                                  # imports the 6 VMs (retries through Proxmox API timeouts)
echo 'bootstrap_cluster = false' >> terraform.tfvars   # manage VMs only, never re-bootstrap
terraform plan                               # expect only a harmless stop_on_destroy flag diff
```
See `terraform/README.md` for the secrets/identity nuance. A full rebuild instead: set
`bootstrap_cluster = true`, `terraform destroy`, `terraform apply`.

---

## C. Restore data ("as it was from where it was")
A fresh rebuild gives the same *config*; stateful *data* comes from the Synology backups.

**Time capsules** (`./load-and-chaos/backup-to-nas.sh`, on `NAS:/volume1/backups/kubeshowcase/`)
each contain: a full git bundle, a cluster snapshot, an **etcd snapshot**, and an
openssl-encrypted blob of the age key + kube/talosconfig + Terraform state.
```bash
# on a fresh machine, recover the repo + secrets from a capsule:
tar xzf kubeshowcase-<ts>.tar.gz && cd kubeshowcase-<ts>
git clone repo.bundle ~/talos-test
openssl enc -d -aes-256-cbc -pbkdf2 -in secrets.tar.enc | tar xz   # age key, kube/talosconfig, TF state
mkdir -p ~/.config/sops/age && cp age-keys.txt ~/.config/sops/age/keys.txt
```

**Volume data (Postgres etc.)** — Longhorn backs every volume up nightly to the Synology NFS
(`NAS:/volume1/backups/longhorn`, off-cluster, survives a full teardown). After a fresh rebuild:
1. Longhorn UI (`https://longhorn.192.168.1.27.nip.io`) → **Backup** → the volume → **Restore**.
2. For Postgres specifically, prefer CNPG bootstrap-from-backup / PITR (see
   `workloads/kubeshowcase/postgres.yaml` `barmanObjectStore`) for a consistent restore.

**etcd snapshot** (whole-cluster k8s state, not volume data) — for restoring the control plane in
place rather than rebuilding: `talosctl bootstrap --recover-from ./etcd-<ts>.snap` (see
`load-and-chaos/runbooks/upgrade-talos-k8s.md`).

**Before a planned teardown**, take a fresh capsule + a Velero/CNPG backup so the most recent
state is off-cluster:
```bash
./load-and-chaos/backup-to-nas.sh        # config + etcd + secrets → NAS
# (Longhorn nightly already covers volumes; trigger an ad-hoc one in the Longhorn UI if needed)
```

---

## What is NOT automatically preserved
- **Vault contents beyond the seed** — a rebuild re-inits Vault fresh (new root/unseal keys); the
  seed script re-creates the demo KV + ESO role. Real secrets you added by hand must be re-added
  (or restore Vault's own storage from a Longhorn backup of the `vault` PVC).
- **In-cluster MinIO data** (Loki/Tempo history, Velero/CNPG backups) lives on Longhorn — back up
  those PVCs too if you need the observability history. Day-to-day, only the app's Postgres data
  is worth restoring; everything else regenerates.
