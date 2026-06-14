# CNI
> The pluggable contract that gives every pod an IP and a route — without it, Kubernetes has no network at all.

**What it is.** CNI ("Container Network Interface") is a *contract*, not a product. It's a tiny spec that says: when the kubelet creates a pod's network namespace, it calls a CNI plugin binary; that plugin gives the pod an interface and an IP, and cleans up on delete. Think of it like a wall-socket standard — Kubernetes provides the socket, and any conforming plugin (Cilium, Calico, Flannel) can plug in. Kubernetes itself has zero networking opinions beyond a few rules (every pod gets its own IP; pods reach each other without NAT).

**How it works.** The kubelet finds CNI config in `/etc/cni/net.d/` and plugin binaries in `/opt/cni/bin/`. When a pod is scheduled, the kubelet creates its network namespace and invokes the plugin, which creates a virtual ethernet pair (`veth` — a virtual patch cable, one end in the pod, one on the host), assigns an IP from the node's pod CIDR, and programs routes so packets can leave the node. Until a CNI is installed, nodes report `NotReady` and pods stay `Pending`.

**In this cluster.**
- Talos is installed with `cni: none` on purpose; [[cilium|Cilium]] is the CNI, installed first at ArgoCD `sync-wave: "0"` (`apps/platform/cilium.yaml`).
- `kubectl get nodes -o wide` — all `Ready` *because* Cilium provides the network (NotReady pre-CNI is expected, per `docs/talos-gotchas.md` #8).

**See also:** [[cilium]] · [[ebpf]] · [[service]] · [[mtu]] · [[talos-linux]] &nbsp; **Deep dive:** [[02-networking]]
