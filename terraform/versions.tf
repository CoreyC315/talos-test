terraform {
  required_version = ">= 1.6"
  required_providers {
    proxmox = {
      source  = "bpg/proxmox" # modern, well-maintained Proxmox provider
      version = "~> 0.66"
    }
    talos = {
      source  = "siderolabs/talos" # official Talos provider (gen config, apply, bootstrap, kubeconfig)
      version = "~> 0.7"
    }
    helm = {
      source  = "hashicorp/helm" # Cilium + Argo CD releases
      version = "~> 2.17"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes" # argocd namespace + sops-age secret
      version = "~> 2.33"
    }
    null  = { source = "hashicorp/null", version = "~> 3.2" }
    local = { source = "hashicorp/local", version = "~> 2.5" }
  }
}
