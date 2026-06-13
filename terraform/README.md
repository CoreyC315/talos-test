# Terraform — Proxmox VMs + Talos bootstrap (the substrate)

This module reproduces the **infrastructure layer** with one command: the 6 Proxmox VMs (with the
final post-incident CPU/RAM sizes) and the full Talos bootstrap (config gen → apply → etcd
bootstrap → kubeconfig). Everything *above* this — Cilium, the whole platform, the app — is already
declarative in Git and arrives via the two `bootstrap/*.sh` scripts + Argo CD.

> Split of responsibility:
> - **Terraform** = Proxmox VMs + Talos OS bootstrap → a bare, `NotReady` (CNI=none) cluster + kubeconfig.
> - **`bootstrap/01` + `02` + Argo CD** = Cilium and every tier, reconciled from Git.
>
> So a full rebuild is: `terraform apply` → 2 bootstrap scripts → walk away.

## What it captures from the manual build
- Final VM sizes (Resilience Report Incident 1 & 4): CPs `4c / 6–8 GiB`, worker-1 `6c / 8 GiB`
  (registry + Gateway L2 announcer), worker-2/3 `6c / 5 GiB`. One CP per Proxmox host.
- The Image Factory schematic ID + installer image (iscsi-tools, util-linux-tools,
  qemu-guest-agent, intel-ucode).
- The committed Talos patches (`../talos/patches/common.yaml`, `cluster.yaml`) — reused via
  `file()`, **single source of truth**: KubePrism, CNI=none, kube-proxy disabled, LUKS2,
  sysctls, the `.23` registry mirror, gateway `.254` (gotcha #1), VIP `.19`, per-host zone labels.

## Usage
```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars   # add your Proxmox API token
terraform init
terraform apply                                 # creates ISOs + 6 VMs + bootstraps Talos

# hand the credentials to the rest of the repo:
terraform output -raw kubeconfig  > ../talos/clusterconfig/kubeconfig
terraform output -raw talosconfig > ../talos/clusterconfig/talosconfig

cd .. && ./bootstrap/01-bootstrap-core.sh && ./bootstrap/02-bootstrap-argocd.sh
```

## Teardown / rebuild
```bash
terraform destroy   # removes the 6 VMs (etcd PKI in state is discarded → fresh cluster next apply)
terraform apply     # clean rebuild
```

## Adopting the EXISTING (manually-built) cluster instead of rebuilding
The live cluster was created by hand, so it is **not** in Terraform state. Two options:
1. **Rebuild** (recommended for a clean slate): `terraform destroy` is a no-op (nothing in state);
   delete the manual VMs in Proxmox, then `terraform apply`.
2. **Import** the existing VMs so Terraform manages them in place:
   ```bash
   terraform import 'proxmox_virtual_environment_vm.talos["cp-1"]' raiden/220
   # …repeat for 221,222,223,224,225 on their hosts…
   ```
   To keep the *existing cluster identity* (so the current kubeconfig/certs keep working), feed the
   committed secrets into `talos_machine_secrets` instead of generating: decrypt
   `../talos/secrets.sops.yaml` and supply it — otherwise a fresh apply mints new PKI.

## Known caveats (homelab realities)
- **Maintenance-IP discovery:** first-boot config is applied to each VM's DHCP IP read from the
  QEMU guest agent (`ipv4_addresses[1][0]` = first IP on `ens18`). If your guest-agent interface
  ordering differs, adjust that index in `talos.tf`. If the agent is slow to report, a second
  `terraform apply` resolves the race.
- **State is sensitive:** it contains the Talos PKI + kubeconfig. `.gitignore` excludes it; use a
  remote backend (e.g. an S3 bucket on the Synology/MinIO) for real use.
- Talos nodes are intentionally **NotReady** after this module finishes — Cilium (installed by
  `bootstrap/01`) provides the CNI.
