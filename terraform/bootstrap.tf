# ── Bootstrap: Cilium + Argo CD, all in the same `terraform apply` ────────────────────────────
# This replaces the manual bootstrap/01 + 02 scripts with declarative resources (Cilium and
# Argo CD as helm_release; the imperative Gateway-API/TLSRoute prep via the shared
# bootstrap/00 script). After the root Application is applied, Argo CD reconciles every tier.

# Write kubeconfig/talosconfig to the repo so kubectl/talosctl + build-and-push.sh work, and so
# the Gateway-API prep script (run below) has a KUBECONFIG to use.
resource "local_sensitive_file" "kubeconfig" {
  count           = var.write_kubeconfig ? 1 : 0
  content         = talos_cluster_kubeconfig.this.kubeconfig_raw
  filename        = "${path.module}/../talos/clusterconfig/kubeconfig"
  file_permission = "0600"
}

resource "local_sensitive_file" "talosconfig" {
  count           = var.write_kubeconfig ? 1 : 0
  content         = data.talos_client_configuration.this.talos_config
  filename        = "${path.module}/../talos/clusterconfig/talosconfig"
  file_permission = "0600"
}

# A kubeconfig file the local-exec provisioner can point at (always written, even if the repo
# copy is disabled), kept in the TF dir so it doesn't collide with the repo's gitignored one.
resource "local_sensitive_file" "kubeconfig_tf" {
  content         = talos_cluster_kubeconfig.this.kubeconfig_raw
  filename        = "${path.module}/.kubeconfig"
  file_permission = "0600"
}

# Gateway API CRDs + the TLSRoute/Cilium gotcha — the one genuinely-imperative step, run via the
# shared script so it can never drift from the manual path.
resource "null_resource" "gateway_api" {
  triggers = {
    script = filemd5("${path.module}/../bootstrap/00-gateway-api-prep.sh")
  }
  provisioner "local-exec" {
    command     = "${path.module}/../bootstrap/00-gateway-api-prep.sh"
    environment = { KUBECONFIG = local_sensitive_file.kubeconfig_tf.filename }
  }
  depends_on = [talos_cluster_kubeconfig.this, local_sensitive_file.kubeconfig_tf]
}

# Cilium — CNI, kube-proxy replacement, Hubble, Gateway API, MTU 1450 (all in the committed values).
resource "helm_release" "cilium" {
  name             = "cilium"
  repository       = "https://helm.cilium.io"
  chart            = "cilium"
  version          = var.cilium_version
  namespace        = "kube-system"
  values           = [file("${path.module}/../platform/cilium/values.yaml")]
  wait             = true
  timeout          = 900
  depends_on       = [null_resource.gateway_api]
}

# LB-IPAM pool + L2 announcement policy (pinned to worker-1). Applied via kubectl (CRs whose CRDs
# Cilium just created) — null_resource keeps it provider-config-free at plan time.
resource "null_resource" "lb_ipam" {
  triggers   = { content = filemd5("${path.module}/../platform/cilium/manifests/lb-ipam.yaml") }
  depends_on = [helm_release.cilium, local_sensitive_file.kubeconfig_tf]
  provisioner "local-exec" {
    command     = "kubectl apply -f ${path.module}/../platform/cilium/manifests/lb-ipam.yaml"
    environment = { KUBECONFIG = local_sensitive_file.kubeconfig_tf.filename }
  }
}

# Argo CD namespace + the SOPS age key (the one secret that cannot live in Git).
resource "kubernetes_namespace" "argocd" {
  metadata { name = "argocd" }
  depends_on = [helm_release.cilium]
}
resource "kubernetes_secret" "sops_age" {
  metadata {
    name      = "sops-age"
    namespace = kubernetes_namespace.argocd.metadata[0].name
  }
  data       = { "keys.txt" = file(pathexpand(var.age_key_file)) }
  depends_on = [kubernetes_namespace.argocd]
}

# Argo CD — same chart + committed values (KSOPS repo-server, 2Gi controller, etc.).
resource "helm_release" "argocd" {
  name       = "argocd"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  version    = var.argocd_chart_version
  namespace  = kubernetes_namespace.argocd.metadata[0].name
  values     = [file("${path.module}/../bootstrap/argocd/values.yaml")]
  wait       = true
  timeout    = 900
  depends_on = [kubernetes_secret.sops_age]
}

# The root app-of-apps. From here Argo CD reconciles every tier from Git.
resource "null_resource" "root_app" {
  triggers   = { content = filemd5("${path.module}/../bootstrap/root-app.yaml") }
  depends_on = [helm_release.argocd, local_sensitive_file.kubeconfig_tf]
  provisioner "local-exec" {
    command     = "kubectl apply -f ${path.module}/../bootstrap/root-app.yaml"
    environment = { KUBECONFIG = local_sensitive_file.kubeconfig_tf.filename }
  }
}
