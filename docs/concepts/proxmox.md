# Proxmox
> A bare-metal hypervisor that turns 3 physical PCs into the 6 VMs this cluster runs on — the "cloud" of this homelab.

**What it is.** Proxmox VE is a hypervisor: software that lets one physical computer pretend to be several isolated virtual machines (VMs). Think of a physical server as an apartment building and each VM as a separate apartment — its own walls (CPU/RAM/disk), its own door, tenants who can't see each other. It's free, open-source, and built on Linux KVM/QEMU. Here it plays the role AWS/GCP would in the cloud: the thing that hands you machines.

**How it works.** Proxmox runs directly on bare metal (it *is* the host OS) and exposes both a web UI and a REST API on port 8006. Every VM has a numeric `vmid`, a host, virtual CPUs/RAM/disks, and virtual NICs bridged onto the LAN. You can create VMs by clicking, with the `qm` CLI, or — as this repo does — by having [[terraform]] call the API. The 6 cluster VMs are spread one-control-plane-one-worker across hosts `raiden`, `aether`, and `nahida` so losing any one box can't break the cluster.

**In this cluster.**
- VM placement (`vmid`, host, IP, size) is declared in `terraform/locals.tf`; VM shape (BIOS, disk, bridge) in `terraform/vms.tf`; API endpoint `https://192.168.1.100:8006/` in `terraform/providers.tf`.
- See it live: `kubectl get nodes -L topology.kubernetes.io/zone` — the `ZONE` column shows the Proxmox host each node runs on.

**See also:** [[terraform]] · [[talos-linux]] · [[scheduling-constraints]] · [[longhorn]] &nbsp; **Deep dive:** [[01-foundations]]
