locals {
  # The Image Factory installer image — same schematic, parameterised version.
  installer_image  = "factory.talos.dev/installer/${var.schematic_id}:${var.talos_version}"
  iso_url          = "https://factory.talos.dev/image/${var.schematic_id}/${var.talos_version}/metal-amd64.iso"
  iso_file_name    = "talos-${var.talos_version}-kubeshowcase.iso"
  cluster_endpoint = "https://${var.cluster_vip}:6443"

  # ── Node inventory ──────────────────────────────────────────────────────────
  # BALANCED topology: exactly one control plane + one worker per Proxmox host, so
  # no single host carries two etcd members OR two Longhorn replica targets. This
  # replaced the original layout where nahida hosted 3 of 6 VMs and became the I/O
  # bottleneck (Resilience Report Incident 5) — worker-3 was moved nahida→raiden.
  # Sizes are host-aware (CP needs etcd RAM headroom; workers sized to each host's
  # real budget): raiden is the small 16 GB host (lean 6+6); aether is tight (shares
  # with the k0s/k3s co-tenants 112+201, ~10 GB); nahida is roomy (33 GB) so its
  # worker gets the most. zone == the Proxmox host → topology-spread keeps replicas
  # off a single host.
  nodes = {
    cp-1     = { vmid = 220, host = "raiden", ip = "192.168.1.20", role = "controlplane", cores = 4, memory = 6144, disk = 40 }
    cp-2     = { vmid = 221, host = "aether", ip = "192.168.1.21", role = "controlplane", cores = 4, memory = 8192, disk = 40 }
    cp-3     = { vmid = 222, host = "nahida", ip = "192.168.1.22", role = "controlplane", cores = 4, memory = 8192, disk = 40 }
    worker-1 = { vmid = 223, host = "aether", ip = "192.168.1.23", role = "worker", cores = 6, memory = 7168, disk = 70 }
    worker-2 = { vmid = 224, host = "nahida", ip = "192.168.1.24", role = "worker", cores = 6, memory = 10240, disk = 70 }
    worker-3 = { vmid = 225, host = "raiden", ip = "192.168.1.25", role = "worker", cores = 4, memory = 6144, disk = 70 }
  }

  control_planes = { for k, v in local.nodes : k => v if v.role == "controlplane" }
  workers        = { for k, v in local.nodes : k => v if v.role == "worker" }

  # The Proxmox hosts the ISO must be downloaded to (one copy per host).
  proxmox_hosts = distinct([for n in local.nodes : n.host])
}
