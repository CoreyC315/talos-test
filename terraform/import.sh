#!/usr/bin/env bash
# Adopt the EXISTING (hand-built) cluster into Terraform state — import the 6 VMs + 3 ISOs so
# Terraform manages them in place (resize, reconfigure) WITHOUT recreating them or touching the
# running Talos/Cilium/Argo CD bootstrap.
#
# After this, work in adopt mode:  terraform plan -var bootstrap_cluster=false
# (Put `bootstrap_cluster = false` in terraform.tfvars to make it the default.)
#
# Prereqs: `terraform init` done, and the Proxmox token available (terraform.tfvars or
# TF_VAR_proxmox_api_token). Safe + idempotent: already-imported resources are skipped.
set -euo pipefail
cd "$(dirname "$0")"

export TF_VAR_bootstrap_cluster=false   # never plan/apply the bootstrap layer while adopting

# The kubernetes/helm providers validate their config_path during import; in adopt mode the real
# kubeconfig isn't written, so drop a harmless stub (never used — no k8s resources are imported).
if [ ! -f .kubeconfig ]; then
  printf 'apiVersion: v1\nkind: Config\nclusters: []\ncontexts: []\nusers: []\n' > .kubeconfig
  chmod 600 .kubeconfig
fi

# "<node-key>:<proxmox_host>:<vmid>"  (plain string list — portable to macOS bash 3.2)
VMS="cp-1:raiden:220 cp-2:aether:221 cp-3:nahida:222 worker-1:aether:223 worker-2:nahida:224 worker-3:nahida:225"

imported() { terraform state list 2>/dev/null | grep -qxF "$1"; }

tf_import() { # address  id
  local addr="$1" id="$2" attempt
  if imported "$addr"; then
    echo "  ✓ already in state: $addr"
    return 0
  fi
  # The Proxmox API on the congested 'nahida' host intermittently times out (HTTP 596) reading
  # disk info — retry a few times.
  for attempt in 1 2 3 4 5; do
    echo "  → importing $addr  ($id)  [attempt $attempt]"
    if terraform import "$addr" "$id"; then
      return 0
    fi
    imported "$addr" && return 0   # sometimes it lands despite a late timeout
    echo "    …retrying in 15s (transient Proxmox API timeout)"
    sleep 15
  done
  echo "  ✗ FAILED to import $addr after retries — re-run import.sh (idempotent) when the host is quieter."
  return 1
}

# Note: the ISOs are NOT imported — proxmox_download_file has no import support, and in adopt mode
# (bootstrap_cluster=false) it isn't managed anyway (the ISOs already exist on the hosts).

echo "==> Importing the 6 Talos VMs"
for entry in $VMS; do
  k="${entry%%:*}"; rest="${entry#*:}"; host="${rest%%:*}"; vmid="${rest##*:}"
  tf_import "proxmox_virtual_environment_vm.talos[\"$k\"]" "$host/$vmid"
done

cat <<'EOT'

==> Done. The VMs + ISOs are now Terraform-managed.

Next:
  1. echo 'bootstrap_cluster = false' >> terraform.tfvars     # make adopt mode the default
  2. terraform plan                                           # expect ~no VM changes
       Expected harmless diffs only:
         - `stop_on_destroy: false -> true` on each VM = a Terraform-only flag (destroy behavior);
           applying it does NOT modify or restart the running VMs.
         - `talos_machine_secrets.this` "to add" = an unused resource; `terraform state rm
           talos_machine_secrets.this` for a perfectly clean plan.

To later REBUILD from scratch instead: set bootstrap_cluster = true, `terraform destroy`, `apply`.
EOT
