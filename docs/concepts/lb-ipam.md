# LB-IPAM & L2 Announcements
> How LoadBalancer Services get a real, reachable IP on bare metal — no cloud, no MetalLB.

**What it is.** On a cloud, a `LoadBalancer` [[service|Service]] magically gets an IP because the cloud has a controller for it; on bare metal there's no such fairy, so LoadBalancer Services sit forever in `<pending>`. **LB-IPAM** ("LoadBalancer IP Address Management") is the [[cilium|Cilium]] controller that hands out IPs from a pool you define. But an IP isn't enough — the LAN must *find* it. **L2 announcements** make a chosen node answer ARP for the VIP ("I have 192.168.1.27, send its packets to my MAC"). Mental model: LB-IPAM is the receptionist assigning desk numbers from a block; L2 announcement is the person who picks up when you dial.

**How it works.** You create a `CiliumLoadBalancerIPPool` (the address block) and a `CiliumL2AnnouncementPolicy` (which Services, which interfaces, which nodes). Cilium's operator assigns an IP per Service; one node wins a per-service **lease** (leader election) and answers via gratuitous ARP. If it dies, the lease moves to another node. **Critical rule:** never run MetalLB *and* Cilium L2 together — both answer ARP and you get a flapping VIP "ARP fight."

**In this cluster.**
- `platform/cilium/manifests/lb-ipam.yaml`: pool `homelab-pool` (`192.168.1.26`–`.30`, 5 IPs) and policy `l2-policy` announcing on `^ens[0-9]+` (Proxmox NIC), `nodeSelector` pinned to `worker-1` (nahida is congested). Enabled via `l2announcements.enabled` + `externalIPs.enabled`; `k8sClientRateLimit` raised (qps 32/burst 64) since L2 leases are chatty.
- `kubectl get ciliumloadbalancerippool homelab-pool` (IPS AVAILABLE); `kubectl -n kube-system get lease | grep l2announce` (holder = `worker-1`).

**See also:** [[cilium]] · [[service]] · [[gateway-api]] · [[proxmox]] · [[ebpf]] &nbsp; **Deep dive:** [[02-networking]]
See [[OPERATIONS]].
