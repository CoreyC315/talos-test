output "talosconfig" {
  description = "Talos client config (talosctl). Also written to talos/clusterconfig/talosconfig."
  value       = data.talos_client_configuration.this.talos_config
  sensitive   = true
}

output "kubeconfig" {
  description = "Kubeconfig (via the VIP). Also written to talos/clusterconfig/kubeconfig."
  value       = var.bootstrap_cluster ? talos_cluster_kubeconfig.this[0].kubeconfig_raw : null
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
    Substrate + Cilium + Argo CD are up; Argo CD is now reconciling every tier from Git
    (give it ~10 min). kubeconfig/talosconfig were written to talos/clusterconfig/.

      export KUBECONFIG=$PWD/../talos/clusterconfig/kubeconfig
      kubectl -n argocd get applications      # watch the fleet converge
      ./../load-and-chaos/build-and-push.sh   # build + push the app images to the in-cluster registry
      ./../security/vault/seed-vault.sh        # one-time Vault init/unseal + ESO wiring
  EOT
}
