# ── Bootstrap: Cilium + Argo CD, all in the same `terraform apply` ────────────────────────────
# Replaces the manual bootstrap/01 + 02 scripts with declarative resources. All of this is gated
# on var.bootstrap_cluster so that adopting the existing hand-built cluster (import.sh) manages
# only the VMs and never re-touches the running bootstrap.
locals {
  do_bootstrap       = var.bootstrap_cluster ? 1 : 0
  kubeconfig_tf_path = "${path.module}/.kubeconfig"
}

# Write kubeconfig/talosconfig to the repo so kubectl/talosctl + build-and-push.sh work.
resource "local_sensitive_file" "kubeconfig" {
  count           = var.bootstrap_cluster && var.write_kubeconfig ? 1 : 0
  content         = talos_cluster_kubeconfig.this[0].kubeconfig_raw
  filename        = "${path.module}/../talos/clusterconfig/kubeconfig"
  file_permission = "0600"
}

resource "local_sensitive_file" "talosconfig" {
  count           = var.bootstrap_cluster && var.write_kubeconfig ? 1 : 0
  content         = data.talos_client_configuration.this.talos_config
  filename        = "${path.module}/../talos/clusterconfig/talosconfig"
  file_permission = "0600"
}

# A private kubeconfig file the local-exec provisioners + the helm/kubernetes providers point at.
resource "local_sensitive_file" "kubeconfig_tf" {
  count           = local.do_bootstrap
  content         = talos_cluster_kubeconfig.this[0].kubeconfig_raw
  filename        = local.kubeconfig_tf_path
  file_permission = "0600"
}

# Gateway API CRDs + the TLSRoute/Cilium gotcha — the one genuinely-imperative step, run via the
# shared script so it can never drift from the manual path.
resource "null_resource" "gateway_api" {
  count    = local.do_bootstrap
  triggers = { script = filemd5("${path.module}/../bootstrap/00-gateway-api-prep.sh") }
  provisioner "local-exec" {
    command     = "${path.module}/../bootstrap/00-gateway-api-prep.sh"
    environment = { KUBECONFIG = local_sensitive_file.kubeconfig_tf[0].filename }
  }
  depends_on = [talos_cluster_kubeconfig.this, local_sensitive_file.kubeconfig_tf]
}

# Cilium — CNI, kube-proxy replacement, Hubble, Gateway API, MTU 1450 (all in the committed values).
resource "helm_release" "cilium" {
  count      = local.do_bootstrap
  name       = "cilium"
  repository = "https://helm.cilium.io"
  chart      = "cilium"
  version    = var.cilium_version
  namespace  = "kube-system"
  values     = [file("${path.module}/../platform/cilium/values.yaml")]
  wait       = true
  timeout    = 900
  depends_on = [null_resource.gateway_api]
}

# LB-IPAM pool + L2 announcement policy (pinned to worker-1), applied via kubectl.
resource "null_resource" "lb_ipam" {
  count      = local.do_bootstrap
  triggers   = { content = filemd5("${path.module}/../platform/cilium/manifests/lb-ipam.yaml") }
  depends_on = [helm_release.cilium, local_sensitive_file.kubeconfig_tf]
  provisioner "local-exec" {
    command     = "kubectl apply -f ${path.module}/../platform/cilium/manifests/lb-ipam.yaml"
    environment = { KUBECONFIG = local_sensitive_file.kubeconfig_tf[0].filename }
  }
}

# Argo CD namespace + the SOPS age key (the one secret that cannot live in Git).
resource "kubernetes_namespace" "argocd" {
  count = local.do_bootstrap
  metadata { name = "argocd" }
  depends_on = [helm_release.cilium]
}
resource "kubernetes_secret" "sops_age" {
  count = local.do_bootstrap
  metadata {
    name      = "sops-age"
    namespace = kubernetes_namespace.argocd[0].metadata[0].name
  }
  data       = { "keys.txt" = file(pathexpand(var.age_key_file)) }
  depends_on = [kubernetes_namespace.argocd]
}

# Argo CD — same chart + committed values (KSOPS repo-server, 2Gi controller, etc.).
resource "helm_release" "argocd" {
  count      = local.do_bootstrap
  name       = "argocd"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  version    = var.argocd_chart_version
  namespace  = kubernetes_namespace.argocd[0].metadata[0].name
  values     = [file("${path.module}/../bootstrap/argocd/values.yaml")]
  wait       = true
  timeout    = 900
  depends_on = [kubernetes_secret.sops_age]
}

# The root app-of-apps. From here Argo CD reconciles every tier from Git.
resource "null_resource" "root_app" {
  count      = local.do_bootstrap
  triggers   = { content = filemd5("${path.module}/../bootstrap/root-app.yaml") }
  depends_on = [helm_release.argocd, local_sensitive_file.kubeconfig_tf]
  provisioner "local-exec" {
    command     = "kubectl apply -f ${path.module}/../bootstrap/root-app.yaml"
    environment = { KUBECONFIG = local_sensitive_file.kubeconfig_tf[0].filename }
  }
}
