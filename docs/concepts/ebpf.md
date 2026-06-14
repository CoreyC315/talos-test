# eBPF
> A way to run small sandboxed programs *inside the live Linux kernel* on events — the engine behind Cilium's fast networking.

**What it is.** eBPF ("extended Berkeley Packet Filter") lets you load tiny, verified, sandboxed programs into the running kernel that fire on events: a packet arrives, a socket connects, a syscall happens. Mental model: instead of routing every decision up to a userspace process (slow context switches) or re-walking giant `iptables` chains, you hand the kernel a purpose-built program plus fast lookup tables (eBPF *maps*) it consults inline. The kernel verifier rejects any program that could crash or loop forever, so it's safe to run in the hot path.

**How it works.** Programs attach at hook points (network driver/XDP, traffic control, sockets, tracepoints) and read/write eBPF maps — hash tables shared between kernel and userspace. [[cilium|Cilium]] attaches programs at the network-driver level so it can make routing, load-balancing, and policy decisions extremely early and fast, storing Service→backend and pod-identity data in maps for O(1) lookups. The same observability hooks let [[hubble|Hubble]] record every flow almost for free.

**In this cluster.**
- Every networking decision runs through Cilium's eBPF (`platform/cilium/values.yaml`): kube-proxy-free [[service|Service]] load balancing, policy, and the [[mtu|VXLAN]] dataplane.
- `kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg service list | head` — ClusterIP frontends mapped to pod backends, served straight from eBPF maps.

**See also:** [[cilium]] · [[cni]] · [[hubble]] · [[service]] · [[falco]] &nbsp; **Deep dive:** [[02-networking]]
