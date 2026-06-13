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
  }
}
