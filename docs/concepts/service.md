# Kubernetes Service
> A stable virtual IP and DNS name in front of a moving set of pods — the cluster's switchboard.

**What it is.** Pods are cattle: they die, restart, and get new IPs constantly. A **Service** is the stable abstraction in front of them — a fixed virtual IP (the **ClusterIP**) and a DNS name that load-balances to whatever pods currently match its label selector. Mental model: pods are gig workers who change phone numbers weekly; a Service is the company switchboard that always rings whoever's on shift. Three types: **ClusterIP** (internal-only VIP), **NodePort** (same high port 30000-32767 on every node's IP), **LoadBalancer** (a real external IP — in the cloud an ELB, here supplied by [[lb-ipam|Cilium LB-IPAM]]).

**How it works.** A Service's selector matches pods; the controller maintains the matching pod IPs in an **EndpointSlice**. The dataplane (kube-proxy classically, [[cilium|Cilium]] [[ebpf|eBPF]] here) programs the ClusterIP→backends mapping so packets to the ClusterIP get DNAT'd to a healthy backend. [[coredns|CoreDNS]] resolves the Service name to its ClusterIP. A LoadBalancer Service is a superset: it still has a ClusterIP and NodePort, plus an external IP.

**In this cluster.**
- The [[gateway-api|Gateway]]'s dataplane surfaces as a `LoadBalancer` Service, `cilium-gateway-shared` in namespace `gateway`.
- `kubectl -n gateway get svc cilium-gateway-shared` — one Service that is `ClusterIP` **and** `EXTERNAL-IP=192.168.1.27` **and** a NodePort, all at once.

**See also:** [[cilium]] · [[coredns]] · [[lb-ipam]] · [[gateway-api]] · [[ebpf]] · [[statefulset]] &nbsp; **Deep dive:** [[02-networking]]
