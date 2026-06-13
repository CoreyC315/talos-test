variable "proxmox_endpoint" {
  type        = string
  description = "Proxmox VE API endpoint, e.g. https://192.168.1.100:8006/"
  default     = "https://192.168.1.100:8006/"
}

variable "proxmox_api_token" {
  type        = string
  sensitive   = true
  description = "Proxmox API token in the form 'user@realm!tokenid=<uuid>'"
}

variable "talos_version" {
  type        = string
  description = "Talos Linux version (must match the Image Factory installer tag)"
  default     = "v1.13.4"
}

variable "kubernetes_version" {
  type        = string
  description = "Kubernetes version Talos installs (must be in the Talos support matrix)"
  default     = "1.35.6"
}

variable "schematic_id" {
  type        = string
  description = "Talos Image Factory schematic ID (iscsi-tools, util-linux-tools, qemu-guest-agent, intel-ucode)"
  default     = "7d1fa2e0d2d77244e6ab651eb49a9772e2c905c87ae4f1bd5833df1d7832a092"
}

variable "cluster_name" {
  type    = string
  default = "kubeshowcase"
}

variable "cluster_vip" {
  type        = string
  description = "Talos built-in control-plane VIP"
  default     = "192.168.1.19"
}

variable "gateway" {
  type        = string
  description = "LAN default gateway (this homelab's is .254, NOT .1 — gotcha #1)"
  default     = "192.168.1.254"
}

variable "nameservers" {
  type    = list(string)
  default = ["192.168.1.102", "1.1.1.1"] # Pi-hole first, Cloudflare fallback
}

variable "proxmox_bridge" {
  type    = string
  default = "vmbr0"
}

variable "image_datastore" {
  type        = string
  description = "Proxmox datastore that holds the downloaded Talos ISO"
  default     = "local"
}

variable "vm_datastore" {
  type        = string
  description = "Proxmox datastore for VM disks"
  default     = "local-lvm"
}

variable "age_key_file" {
  type        = string
  description = "Path to the SOPS age private key (mounted into Argo CD repo-server for KSOPS). Never committed."
  default     = "~/.config/sops/age/keys.txt"
}

variable "cilium_version" {
  type    = string
  default = "1.19.4"
}

variable "argocd_chart_version" {
  type    = string
  default = "9.5.21" # Argo CD v3.4.3 — see versions.lock.md
}

variable "write_kubeconfig" {
  type        = bool
  description = "Write kubeconfig/talosconfig to ../talos/clusterconfig/ for kubectl/talosctl + the build script"
  default     = true
}
