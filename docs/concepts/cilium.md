# Cilium
> The eBPF dataplane that is CNI + kube-proxy + load balancer + Gateway + observability, all in one.

**What it is.** Cilium is a [[cni|CNI]] that does pod networking, Service load balancing, and security using [[ebpf|eBPF]] instead of traditional Linux `iptables`. Mental model: classic kube-proxy is like a paper phone directory the kernel re-reads top-to-bottom for every call — slow, and it grows linearly with the number of Services; eBPF gives the kernel an O(1) hash-map instead. In this cluster Cilium does an unusually large amount: it's the pod network, it replaces kube-proxy, it hands out external IPs ([[lb-ipam|LB-IPAM]]), implements the [[gateway-api|Gateway API]], and ships [[hubble|Hubble]].

**How it works.** A `cilium-agent` DaemonSet runs one pod per node, programming eBPF maps for which pod IP lives where, how to reach each Service's backends, and what policy applies. With `kubeProxyReplacement: true`, Cilium implements [[service|Service]] load balancing itself in eBPF and Talos runs **no kube-proxy at all**. To avoid a chicken-and-egg (Cilium needs the API server, which is itself a Service), it points at Talos [[kubeprism|KubePrism]] (`localhost:7445`). Cross-node pod traffic rides a [[mtu|VXLAN overlay]].

**In this cluster.**
- `platform/cilium/values.yaml` is the whole config: `kubeProxyReplacement: true`, `k8sServiceHost: localhost` + `k8sServicePort: 7445`, `ipam.mode: kubernetes`. Talos capabilities/cgroup tweaks exist because it's a locked-down immutable OS.
- `kubectl -n kube-system get ds kube-proxy` → `NotFound` (proof there's no kube-proxy); `kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg status | grep KubeProxyReplacement` → `True`.

**See also:** [[cni]] · [[ebpf]] · [[hubble]] · [[service]] · [[lb-ipam]] · [[kubeprism]] &nbsp; **Deep dive:** [[02-networking]]
See [[OPERATIONS]].
