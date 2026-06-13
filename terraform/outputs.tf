output "talosconfig" {
  description = "Talos client config (talosctl) — write to talos/clusterconfig/talosconfig"
  value       = talos_machine_secrets.this.client_configuration
  sensitive   = true
}

output "kubeconfig" {
  description = "Kubeconfig for the cluster (via the VIP). Write to talos/clusterconfig/kubeconfig"
  value       = talos_cluster_kubeconfig.this.kubeconfig_raw
  sensitive   = true
}

output "control_plane_ips" {
  value = [for k, v in local.control_planes : v.ip]
}

output "worker_ips" {
  value = [for k, v in local.workers : v.ip]
}

output "cluster_vip" {
  value = var.cluster_vip
}

output "next_steps" {
  value = <<-EOT
    Cluster substrate is up (nodes will be NotReady until Cilium installs — expected, CNI=none).
    1. terraform output -raw kubeconfig  > ../talos/clusterconfig/kubeconfig
    2. terraform output -raw talosconfig > ../talos/clusterconfig/talosconfig
    3. cd .. && ./bootstrap/01-bootstrap-core.sh   # Cilium + Gateway API CRDs
    4.          ./bootstrap/02-bootstrap-argocd.sh  # Argo CD + age key + root app-of-apps
    ArgoCD then reconciles every tier from Git. Build app images: ./load-and-chaos/build-and-push.sh
  EOT
}
