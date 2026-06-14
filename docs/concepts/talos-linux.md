# Talos Linux
> An immutable, API-only Linux OS that exists solely to run Kubernetes — no SSH, no shell, no package manager.

**What it is.** Talos is a Linux distro stripped to the minimum needed to run Kubernetes, then locked shut. There is no SSH, no `/bin/bash`, no `apt` to log into; you talk to it over a secure gRPC API with `talosctl`. Mental model: a normal Linux box is a workshop you can rearrange (and break); Talos is a sealed appliance like a microwave — you send it a config document and it makes itself match. The root filesystem is read-only, so config drift and most malware persistence simply can't happen.

**How it works.** Each node gets one YAML *machine config* describing everything (install disk, network, k8s version, certs, sysctls); you generate it (here [[terraform]]'s talos provider does) and apply it, then the node reconfigures and reboots into that state. Rather than one giant file, settings layer as *patches* on a generated base. The OS ships as a minimal image plus optional *system extensions* declared in a *schematic* submitted to the hosted Image Factory, which returns a content-addressed schematic ID (same in → same image out, forever).

**In this cluster.**
- `talos/schematic.yaml` (4 extensions: iscsi-tools, util-linux-tools, qemu-guest-agent, intel-ucode), `talos/patches/common.yaml` (install `/dev/sda`, [[kubeprism]] :7445, LUKS2 encryption, registry mirrors), `talos/patches/cluster.yaml` (CP-only: `cni: none`, `proxy: disabled`), `talos/patches/nodes/*.yaml` (per-node hostname/IP/zone; cp-1 carries the VIP).
- See it live (`export TALOSCONFIG=$PWD/talos/clusterconfig/talosconfig`): `talosctl -n 192.168.1.20 get extensions` — internals with no shell.

**See also:** [[proxmox]] · [[terraform]] · [[kubeprism]] · [[etcd]] · [[cilium]] · [[kubelet]] &nbsp; **Deep dive:** [[01-foundations]]
