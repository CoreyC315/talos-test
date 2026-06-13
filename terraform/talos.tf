# ── Talos machine secrets ─────────────────────────────────────────────────────
# Generated once and stored in Terraform state. A `destroy`+`apply` mints a fresh cluster
# identity (correct for a clean rebuild). To instead preserve the EXISTING cluster's identity,
# import the committed bundle: decrypt talos/secrets.sops.yaml and `terraform import` /
# feed it via the talos_machine_secrets `machine_secrets` input. (See terraform/README.md.)
resource "talos_machine_secrets" "this" {
  talos_version = var.talos_version
}

# Reuse the committed Talos patches as the single source of truth — no duplication.
locals {
  common_patch  = file("${path.module}/../talos/patches/common.yaml")  # install image, KubePrism, LUKS2, sysctls, registry mirrors (.23)
  cluster_patch = file("${path.module}/../talos/patches/cluster.yaml") # CP-only: CNI none, kube-proxy disabled, certSANs

  node_patches = {
    for k, v in local.nodes : k => templatefile("${path.module}/templates/node-patch.yaml.tftpl", {
      hostname         = k
      ip               = v.ip
      gateway          = var.gateway
      vip              = var.cluster_vip
      zone             = v.host
      is_controlplane  = v.role == "controlplane"
    })
  }
}

# Base machine configuration per role.
data "talos_machine_configuration" "this" {
  for_each         = local.nodes
  cluster_name     = var.cluster_name
  cluster_endpoint = local.cluster_endpoint
  machine_type     = each.value.role
  machine_secrets  = talos_machine_secrets.this.machine_secrets
  kubernetes_version = var.kubernetes_version
  talos_version    = var.talos_version
}

# Apply config to each node. The endpoint is the node's MAINTENANCE-mode DHCP IP, read from the
# QEMU guest agent; the config then assigns the static IP (.20–.25) and the node reboots into it.
resource "talos_machine_configuration_apply" "this" {
  for_each = var.bootstrap_cluster ? local.nodes : {} # empty when adopting existing VMs

  client_configuration        = talos_machine_secrets.this.client_configuration
  machine_configuration_input = data.talos_machine_configuration.this[each.key].machine_configuration

  # First boot: the VM is in maintenance mode on a DHCP address reported by the agent.
  node     = each.value.ip                                                     # final identity
  endpoint = proxmox_virtual_environment_vm.talos[each.key].ipv4_addresses[1][0] # maintenance DHCP IP (ens18)

  config_patches = compact([
    local.common_patch,
    each.value.role == "controlplane" ? local.cluster_patch : "",
    local.node_patches[each.key],
  ])

  depends_on = [proxmox_virtual_environment_vm.talos]
}

# Bootstrap etcd on exactly one control-plane node (cp-1), once its config is applied.
resource "talos_machine_bootstrap" "this" {
  count                = var.bootstrap_cluster ? 1 : 0
  depends_on           = [talos_machine_configuration_apply.this]
  node                 = local.nodes["cp-1"].ip
  endpoint             = local.nodes["cp-1"].ip
  client_configuration = talos_machine_secrets.this.client_configuration
}

# Ready-to-use talosconfig (talosctl client config) pointing at the control planes + VIP.
data "talos_client_configuration" "this" {
  cluster_name         = var.cluster_name
  client_configuration = talos_machine_secrets.this.client_configuration
  nodes                = [for k, v in local.control_planes : v.ip]
  endpoints            = [for k, v in local.control_planes : v.ip]
}

# Pull the kubeconfig once the cluster is bootstrapped.
resource "talos_cluster_kubeconfig" "this" {
  count                = var.bootstrap_cluster ? 1 : 0
  depends_on           = [talos_machine_bootstrap.this]
  node                 = local.nodes["cp-1"].ip
  endpoint             = var.cluster_vip
  client_configuration = talos_machine_secrets.this.client_configuration
}

# Optional health gate so `apply` blocks until the cluster is actually up.
data "talos_cluster_health" "this" {
  count                = var.bootstrap_cluster ? 1 : 0
  depends_on           = [talos_cluster_kubeconfig.this]
  client_configuration = talos_machine_secrets.this.client_configuration
  control_plane_nodes  = [for k, v in local.control_planes : v.ip]
  worker_nodes         = [for k, v in local.workers : v.ip]
  endpoints            = [for k, v in local.control_planes : v.ip]
  # Nodes stay NotReady until Cilium is installed (CNI=none) — skip the k8s-Ready check here.
  skip_kubernetes_checks = true
}
