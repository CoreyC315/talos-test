provider "proxmox" {
  endpoint  = var.proxmox_endpoint  # https://192.168.1.100:8006/
  api_token = var.proxmox_api_token # terraform-prov@pve!terraform-token=<uuid>
  insecure  = true                  # self-signed PVE cert

  # The bpg provider uses SSH for a few operations (e.g. file uploads). ISO download via the
  # PVE API (download_file) does NOT need SSH, and that is all we use — so ssh is left default.
  ssh {
    agent = true
  }
}

# The k8s-layer providers are configured from a kubeconfig FILE that the Talos bootstrap writes
# during this same apply (terraform/.kubeconfig). Using a static file path (not inline,
# known-after-apply cluster credentials) lets `terraform plan` succeed on a fresh build — the
# providers defer connecting until apply, by which point the file (and cluster) exist.
provider "helm" {
  kubernetes {
    config_path = "${path.module}/.kubeconfig"
  }
}

provider "kubernetes" {
  config_path = "${path.module}/.kubeconfig"
}
