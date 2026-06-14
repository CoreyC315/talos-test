# CoreDNS
> The cluster's internal phone book — resolves Service names like `argocd-server` to ClusterIPs.

**What it is.** Nothing inside the cluster talks to raw IPs by choice — code says `http://argocd-server` or `postgres.db.svc.cluster.local`. **CoreDNS** is the DNS server that resolves those names to ClusterIPs (and pod IPs). Mental model: it's the cluster's internal phone book, automatically kept in sync with every [[service|Service]]. Every pod is configured via its `/etc/resolv.conf` (written by the [[kubelet]]) to ask CoreDNS first.

**How it works.** CoreDNS runs as a Deployment, fronted by a Service named `kube-dns` at a well-known ClusterIP (`10.96.0.10` here). Its config is a `Corefile` (a plugin chain). The `kubernetes` plugin watches the API and answers `*.svc.cluster.local` from live Service/Endpoint data; anything else (e.g. `github.com`) is `forward`ed upstream. A Service `argocd-server` in namespace `argocd` resolves at `argocd-server.argocd.svc.cluster.local`, and search-domain magic lets a same-namespace pod use the short name.

**In this cluster.**
- Talos ships CoreDNS as a core component (2 replicas). The `192.168.1.27.nip.io` hostnames rely on public `nip.io` wildcard DNS (`anything.192.168.1.27.nip.io` → `192.168.1.27`), so there are no records to manage.
- `kubectl -n kube-system get svc kube-dns` (ClusterIP `10.96.0.10`); `kubectl -n kube-system get cm coredns -o yaml` shows the Corefile plugin chain.

**See also:** [[service]] · [[cilium]] · [[gateway-api]] · [[kubelet]] · [[talos-linux]] &nbsp; **Deep dive:** [[02-networking]]
