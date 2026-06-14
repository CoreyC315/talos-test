# Module 2: Networking — How Pods Talk, and How the World Reaches In

> Networking is where most "my app is healthy but nothing works" incidents actually live, so it's
> the single highest-leverage topic for a platform/SRE/DevOps job. By the end of this module you'll
> be able to explain (and debug, on your own running cluster) the entire path a packet takes: from
> one pod to another across nodes, from a Service name to a backend, and from a browser on your LAN
> all the way to a container — including *why* this cluster runs no kube-proxy, hands out LoadBalancer
> IPs without any cloud, and once silently dropped every large transfer because of a 50-byte header.

## The big picture

Kubernetes deliberately ships **without** a network. The scheduler will happily place pods, but
something has to give every pod an IP, route packets between nodes, implement `Service` load
balancing, and resolve names. That "something" is a **CNI plugin** (Container Network Interface).
In this cluster the CNI is **Cilium**, and Cilium does an unusually large amount: it's the pod
network, it *replaces* kube-proxy, it hands out external IPs for `LoadBalancer` Services, it
implements the Gateway API for ingress, and it ships **Hubble** for observability. **CoreDNS**
provides DNS. **Envoy** (bundled inside Cilium) is the L7 proxy that actually terminates TLS and
routes HTTP at the edge.

Here's the whole north-south + east-west picture for this repo:

```
            Your laptop / phone on 192.168.1.0/24
                         |
                         |  https://argocd.192.168.1.27.nip.io
                         v
        ARP: "who has 192.168.1.27?"  <-- Cilium L2 announcement (worker-1 answers)
                         |
                         v
   +-----------------------------------------------------+
   |  Gateway "shared" (192.168.1.27)  == cilium-envoy    |   <-- north-south edge (L7)
   |    listener :443 HTTPS  (terminates wildcard TLS)    |
   |    listener :80  HTTP                                 |
   +-----------------------------------------------------+
        | HTTPRoute argocd  -> Service argocd-server:80
        | HTTPRoute grafana -> Service grafana:80   ... (one per app)
        v
   +-----------------------------------------------------+
   |  Service (ClusterIP)  -- a stable VIP + DNS name      |   <-- east-west (L3/L4)
   |  load-balanced by Cilium eBPF (NO kube-proxy)        |
   +-----------------------------------------------------+
        |
        v
   Pod  <----VXLAN tunnel (UDP/8472, MTU 1450)----> Pod on another node
        (CoreDNS resolves Service names to ClusterIPs along the way)
```

Two directions to keep straight:

- **East-west** = traffic *inside* the cluster (pod-to-pod, pod-to-Service). Handled by the CNI +
  Services + DNS + the VXLAN overlay.
- **North-south** = traffic *into* the cluster from the outside world (your browser). Handled by
  LB-IPAM/L2 announcements + the Gateway + Envoy.

## Tools in this module

### The CNI concept — give every pod an IP and a route, via a pluggable standard

- **What it is / mental model:** CNI ("Container Network Interface") is a *contract*, not a product.
  It's a tiny spec that says: "when the kubelet creates a pod's network namespace, it will call a
  CNI plugin binary with `ADD`; that plugin must give the pod a network interface and an IP, and on
  `DEL` clean it up." Think of it like a wall socket standard: Kubernetes provides the socket; any
  conforming plugin (Cilium, Calico, Flannel, AWS VPC CNI...) can plug in. Kubernetes itself has
  **zero** networking opinions beyond a few rules (every pod gets its own IP; pods can reach each
  other without NAT). Everything else is the CNI's job.
- **How it works:** the kubelet finds CNI config in `/etc/cni/net.d/` and plugin binaries in
  `/opt/cni/bin/`. When a pod is scheduled, the kubelet creates the pod's network namespace and
  invokes the configured CNI plugin, which: creates a virtual ethernet pair (`veth` — like a virtual
  patch cable with one end in the pod, one on the host), assigns an IP from the node's pod CIDR,
  and programs routes so the packet can leave the node. Until a CNI is installed, nodes report
  `NotReady` and pods stay `Pending` (`Network plugin returns error: cni plugin not initialized`).
- **In THIS cluster:** Talos is installed with `cni: none` on purpose — Cilium is the CNI and is
  installed first (ArgoCD `sync-wave: "0"`, see `apps/platform/cilium.yaml:7`). That's exactly why
  `docs/talos-gotchas.md` (#8) lists "NotReady nodes pre-CNI → expected." See it live:
  ```
  export KUBECONFIG=$PWD/terraform/.kubeconfig
  kubectl get nodes -o wide          # all Ready now, because Cilium is the CNI
  kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg status --brief   # prints "OK"
  ```
  Look for: every node `Ready`, and a healthy Cilium agent on each node.
- **Job relevance:** "What is CNI and what does it do?" is a near-guaranteed CKA networking question.
  Interviewers want to hear: it's an interface/contract, the kubelet calls it, it assigns pod IPs and
  programs routes, and a missing/broken CNI is why nodes go NotReady. Maps to **CKA** (Services &
  Networking is ~20% of the exam).
- **Learn it:** kubernetes.io → search "Network Plugins" and "Cluster Networking" (the
  "Kubernetes network model" section — the four requirements). The CNI spec itself lives at the
  `containernetworking/cni` GitHub project (read the `SPEC.md`).

### Cilium — the eBPF dataplane that is CNI + kube-proxy + LB all in one

- **What it is / mental model:** Cilium is a CNI that does networking, load balancing, and security
  using **eBPF** instead of the traditional Linux `iptables`. eBPF lets you load small sandboxed
  programs *into the running kernel* that run on events (a packet arrives, a socket connects). Mental
  model: classic kube-proxy is like a paper phone directory that the operator (the kernel) re-reads
  top-to-bottom for every call — slow and it grows linearly with the number of Services. eBPF is like
  giving the kernel a hash-map it can look up in O(1). Cilium loads these programs at the network
  driver level so it can make routing/load-balancing/policy decisions extremely early and fast.
- **How it works:** a `cilium-agent` DaemonSet runs one pod per node. Each agent programs eBPF maps
  in its node's kernel: which pod IP lives where, how to reach each Service's backends, what network
  policies apply. Three pieces matter in this cluster:
  - **kube-proxy-free:** with `kubeProxyReplacement: true`, Cilium implements `Service` load
    balancing itself in eBPF and Talos runs **no kube-proxy DaemonSet at all**. No giant iptables
    chains to walk.
  - **KubePrism:** kube-proxy-free creates a chicken-and-egg problem — Cilium needs to reach the API
    server, but the API server is *itself* a Service that Cilium would normally provide. Talos solves
    this with **KubePrism**: a tiny load balancer Talos runs on every node at `localhost:7445` that
    proxies to a healthy API server. So Cilium points at `localhost:7445` and never depends on a VIP
    or a Service it hasn't programmed yet.
  - **VXLAN tunnel mode + eBPF:** pod-to-pod traffic across nodes is encapsulated in VXLAN (see the
    overlay section below).
- **In THIS cluster:** `platform/cilium/values.yaml` is the whole config. Key lines:
  `kubeProxyReplacement: true` (line 3), `k8sServiceHost: localhost` + `k8sServicePort: 7445` (lines
  5-6, the KubePrism endpoint), `ipam: mode: kubernetes` (line 9, Kubernetes hands out the pod
  CIDRs). The Talos-specific `securityContext.capabilities` and pre-mounted `cgroup.hostRoot` (lines
  11-33) exist because Talos is a locked-down immutable OS — Cilium can't load kernel modules itself
  (`docs/talos-gotchas.md` #8 / the values header comment). See it live:
  ```
  export KUBECONFIG=$PWD/terraform/.kubeconfig
  kubectl -n kube-system get ds kube-proxy          # -> "NotFound": proof there is no kube-proxy
  kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg status | grep -i KubeProxyReplacement
  kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg service list | head   # Services in eBPF
  ```
  Look for: `kube-proxy` reported `NotFound`; `KubeProxyReplacement: True`; a `cilium-dbg service
  list` showing ClusterIP frontends (e.g. `10.96.0.10:53` for DNS) mapped to pod backends.
- **Job relevance:** Cilium and eBPF are *the* hot networking skill in 2025-era platform hiring.
  Expect: "what does kube-proxy do and how would you replace it?", "iptables vs IPVS vs eBPF
  tradeoffs", "how does a Service get load-balanced without kube-proxy?". Cilium concepts overlap
  **CKA** (Services) and **CKS** (network policy enforcement, a Cilium strength).
- **Learn it:** cilium.io → docs, sections "Introduction / Component Overview", "Kubernetes Without
  kube-proxy", and "Routing" (tunnel/VXLAN vs native). For eBPF fundamentals: ebpf.io (Cilium's sister
  project) "What is eBPF?".

### Hubble — turn the invisible network into a flow log you can actually read

- **What it is / mental model:** Hubble is Cilium's built-in network observability layer. Because
  Cilium already sees every packet in eBPF, it can cheaply *record* each flow (who talked to whom, on
  what port, allowed or dropped, and even HTTP method/status with L7 visibility). Mental model:
  `tcpdump` shows you raw packets on one interface; Hubble is a cluster-wide flow recorder with the
  Kubernetes identities already attached — "pod `argocd-server` → Service `kube-dns` UDP/53,
  forwarded" instead of "10.244.2.103 → 10.96.0.10". It's the single best tool for answering "why
  can't A reach B?".
- **How it works:** each `cilium-agent` exposes a local Hubble server reading its node's eBPF flow
  events. **hubble-relay** aggregates all nodes into one cluster-wide stream. **hubble-ui** is a web
  UI that draws a live service map. There's also a CLI (`hubble observe`) for grepping flows. Cilium
  also exports Hubble **metrics** (dns/drop/tcp/flow/http) to Prometheus.
- **In THIS cluster:** enabled in `platform/cilium/values.yaml` (lines 48-70): `hubble.enabled`,
  `relay.enabled`, `ui.enabled`, and a metrics block including `httpV2` with exemplars. The UI is
  exposed at `hubble.192.168.1.27.nip.io` via an HTTPRoute in `kube-system` (you saw it in
  `kubectl get httproute -A`). See it live:
  ```
  export KUBECONFIG=$PWD/terraform/.kubeconfig
  kubectl -n kube-system get pods | grep -E 'hubble-relay|hubble-ui'   # both Running
  cilium hubble port-forward &                 # cilium CLI opens relay on :4245
  hubble observe --last 20                      # 20 recent flows (if hubble CLI installed)
  # or just open the UI in a browser:
  open https://hubble.192.168.1.27.nip.io       # service map; click a namespace
  ```
  Look for: a stream of flows tagged `FORWARDED` (and any `DROPPED` ones — those are your bugs). In
  the UI, the namespace service map shows arrows between workloads.
- **Job relevance:** observability is half the SRE job. "How would you debug a connection that's
  being dropped between two pods?" — naming Hubble (or eBPF flow logs) and showing you'd look for
  DROPPED verdicts and policy denials is a strong answer. Not a cert objective per se, but supports
  CKS network-policy troubleshooting.
- **Learn it:** cilium.io → docs "Observability / Hubble" (the "Setting up Hubble Observability" and
  "hubble CLI" pages). For the metrics: same docs, "Hubble Metrics".

### Kubernetes Services — a stable name and VIP in front of a moving set of pods

- **What it is / mental model:** Pods are cattle: they die, restart, and get new IPs constantly. A
  **Service** is the stable abstraction in front of them — a fixed virtual IP (the **ClusterIP**) and
  a DNS name that load-balances to whatever pods currently match its label selector. Mental model:
  pods are gig workers who change phone numbers weekly; a Service is the *company switchboard
  number* that always rings whoever's on shift. The three types you must know:
  - **ClusterIP** (default): reachable only *inside* the cluster. The switchboard has an internal
    extension.
  - **NodePort:** opens the same port on *every node's IP* (range 30000-32767) and forwards in. The
    switchboard also has a direct outside line on a high-numbered port on every building.
  - **LoadBalancer:** asks the platform for a real external IP. In the cloud this provisions an ELB;
    on bare metal you need something to supply the IP (here: Cilium LB-IPAM).
- **How it works:** a Service's selector matches pods; the controller maintains the matching pod IPs
  in an **EndpointSlice**. The dataplane (kube-proxy classically, **Cilium eBPF** here) programs the
  ClusterIP→backends mapping so any packet to the ClusterIP gets DNAT'd to a healthy backend. A
  `LoadBalancer` Service is a *superset*: it still has a ClusterIP and (usually) a NodePort, plus an
  external IP.
- **In THIS cluster:** the Gateway's data plane surfaces as a `LoadBalancer` Service. You can see
  all three layers at once:
  ```
  export KUBECONFIG=$PWD/terraform/.kubeconfig
  kubectl -n gateway get svc cilium-gateway-shared
  # TYPE=LoadBalancer  CLUSTER-IP=10.106.108.21  EXTERNAL-IP=192.168.1.27  PORT(S)=80:32415,443:30141
  kubectl get endpointslices -A | grep argocd-server     # the pod IPs behind a ClusterIP
  kubectl -n kube-system get svc kube-dns                 # ClusterIP 10.96.0.10 (DNS)
  ```
  Look for: one Service showing a ClusterIP **and** an EXTERNAL-IP **and** a NodePort
  (`80:32415/TCP`) — that's a LoadBalancer being all three things at once.
- **Job relevance:** absolutely core CKA/CKAD material. Expect: "difference between ClusterIP,
  NodePort, LoadBalancer", "how does a Service find its pods?" (selector → EndpointSlice),
  "ClusterIP vs headless Service", "what's the NodePort range?". Be able to write a Service YAML from
  memory. Maps to **CKA** and **CKAD**.
- **Learn it:** kubernetes.io → "Service" concept page (read ServiceTypes top to bottom) and
  "Connecting Applications with Services" tutorial. Also "EndpointSlices".

### Cilium LB-IPAM + L2 announcements — give LoadBalancer Services real IPs on bare metal

- **What it is / mental model:** On a cloud, a `LoadBalancer` Service magically gets a public IP
  because the cloud provider has a controller for it. On bare metal / a homelab there is no such
  fairy — by default LoadBalancer Services sit forever in `<pending>`. **LB-IPAM** ("LoadBalancer IP
  Address Management") is the controller that hands out IPs from a pool you define. But handing out an
  IP isn't enough; the LAN has to *find* that IP. **L2 announcements** make a chosen node answer ARP
  ("layer-2") for the VIP — it shouts "I have 192.168.1.27, send its packets to my MAC." This is the
  same job MetalLB does in L2 mode; Cilium absorbs it so you run one fewer component. Mental model:
  LB-IPAM is the receptionist assigning desk phone numbers from a block; L2 announcement is the
  person who picks up when someone dials that number.
- **How it works:** you create a `CiliumLoadBalancerIPPool` (the address block) and a
  `CiliumL2AnnouncementPolicy` (which Services to announce, on which interfaces, from which nodes).
  Cilium's operator assigns an IP from the pool to each `LoadBalancer` Service; one node wins a
  per-service **lease** (leader election) and answers ARP for that VIP via gratuitous ARP. If that
  node dies, the lease moves and another node takes over. **Critical rule:** never run MetalLB *and*
  Cilium L2 at the same time — both answer ARP and you get an "ARP fight" with a flapping VIP.
- **In THIS cluster:** `platform/cilium/manifests/lb-ipam.yaml` defines pool `homelab-pool` with
  block `192.168.1.26`–`192.168.1.30` (5 IPs), and policy `l2-policy` that announces on interfaces
  matching `^ens[0-9]+` (the Proxmox virtio NIC). Note the deliberate `nodeSelector` pinning the
  announcer to `worker-1` (line 21) — `docs/talos-gotchas.md` #13 explains why: L2 re-election can
  wedge after node churn, so pinning to one reliable node makes it deterministic. The values enable
  it: `l2announcements.enabled`, `externalIPs.enabled`, and a raised `k8sClientRateLimit` (qps 32 /
  burst 64) because "L2 leases are chatty" (values.yaml lines 40-46). See it live:
  ```
  export KUBECONFIG=$PWD/terraform/.kubeconfig
  kubectl get ciliumloadbalancerippool homelab-pool      # IPS AVAILABLE shows how many are free
  kubectl get ciliuml2announcementpolicy l2-policy
  kubectl -n kube-system get lease | grep l2announce      # the per-Service announcement leases
  # who holds the gateway VIP lease right now?
  kubectl -n kube-system get lease -o wide | grep -i gateway
  ```
  Look for: pool `DISABLED=false CONFLICTING=False IPS AVAILABLE=4` (one is taken by the Gateway);
  L2 leases whose holder is the `cilium` pod on `worker-1`.
- **Job relevance:** "How do you get a LoadBalancer Service IP on bare metal?" is the classic
  homelab/on-prem interview question — answer: MetalLB or Cilium LB-IPAM, in L2 (ARP) or BGP mode.
  Knowing the ARP-fight pitfall and leader-election failover shows real operational depth. Not a core
  cert objective but very common in platform interviews.
- **Learn it:** cilium.io → docs "LoadBalancer IP Address Management (LB IPAM)" and "L2
  Announcements / L2 Aware LB". For the alternative, metallb.universe.tf → "Concepts" (L2 vs BGP).

### The Gateway API (vs legacy Ingress) — the modern, role-split way to route traffic in

- **What it is / mental model:** **Ingress** was Kubernetes' original "let HTTP in" object, but it
  was thin: anything beyond a hostname/path needed vendor-specific annotations, and there was no clean
  split between "cluster operator owns the load balancer" and "app team owns their routes." The
  **Gateway API** is the successor: a richer, portable, *role-oriented* set of resources. Mental
  model: Ingress is one overloaded form everyone scribbles annotations on; Gateway API is a proper
  org chart — the infra team owns the `GatewayClass` and `Gateway` (the actual listener + TLS), and
  each app team owns its own `HTTPRoute` attaching to that Gateway. It's also protocol-aware (HTTP,
  TLS, gRPC, TCP) instead of HTTP-only.
- **How it works:** three layered resources (see next section), implemented by a controller (here
  Cilium). The key win over Ingress is **separation of concerns** + standardized features (header
  matching, traffic splitting, request mirroring) in the *spec itself*, not annotations — so the same
  YAML works across implementations.
- **In THIS cluster:** the cluster uses Gateway API exclusively — there are no Ingress objects. One
  shared Gateway, many HTTPRoutes (you saw 8 in `kubectl get httproute -A`). The CRDs are installed
  before Cilium in bootstrap (`bootstrap/00-gateway-api-prep.sh`), and `gatewayAPI.enabled: true` in
  `platform/cilium/values.yaml:36-37` turns on Cilium's implementation. See it live:
  ```
  export KUBECONFIG=$PWD/terraform/.kubeconfig
  kubectl get gatewayclass                 # "cilium"  (the implementation)
  kubectl get ingress -A                   # empty — this cluster has NONE
  kubectl get gateway,httproute,tlsroute -A
  ```
  Look for: a `GatewayClass` named `cilium` with `ACCEPTED=True`, and zero Ingress objects.
- **Job relevance:** Gateway API is the direction the whole ecosystem is moving (Ingress is
  effectively frozen). Interviewers increasingly ask "Ingress vs Gateway API — why the change?".
  Strong answer: role separation (GatewayClass/Gateway/Route owned by different teams), native
  multi-protocol + L7 features without annotations, portability across implementations. Maps to
  **CKAD** (exposing apps) and **CKA** (it's replacing Ingress in the curriculum's trajectory).
- **Learn it:** gateway-api.sigs.k8s.io → "Introduction" and "API Overview / Roles and personas".
  Compare with kubernetes.io → "Ingress" concept (to feel the annotation pain it fixes).

### Gateway / HTTPRoute / TLSRoute — the three layers, and the TLSRoute version saga

- **What it is / mental model:** the Gateway API splits ingress into three resources:
  - **GatewayClass** — *which* implementation (like a StorageClass, but for ingress). Here: `cilium`.
  - **Gateway** — an actual listener: IP, ports, protocols, TLS certs. Owned by the platform team.
    Analogy: the building's front desk — one physical entrance, a guard, the door at :443.
  - **HTTPRoute** (and **TLSRoute**, **GRPCRoute**, **TCPRoute**) — routing rules that *attach* to a
    Gateway via `parentRefs` and say "hostname `argocd.…` → Service `argocd-server:80`." Owned by
    each app team. Analogy: the lobby directory mapping visitor names to floors.
  - **TLSRoute** specifically routes by SNI for *TLS passthrough* (the Gateway forwards encrypted
    bytes without decrypting), vs HTTPRoute where the Gateway terminates TLS and routes on HTTP.
- **How it works:** the controller watches Gateways and Routes. A Route lists `parentRefs` to a
  Gateway (possibly cross-namespace, which the Gateway must allow via `allowedRoutes`). The Gateway
  declares listeners; a Route binds to a matching listener by hostname/port. The controller then
  programs the data plane (Envoy) to terminate TLS on the HTTPS listener and route each hostname to
  the right Service.
- **In THIS cluster:**
  - `platform/gateway/gateway.yaml` defines the one shared Gateway (`name: shared`, namespace
    `gateway`, `gatewayClassName: cilium`). It pins itself to `192.168.1.27` via
    `lbipam.cilium.io/ips` (line 28) so the nip.io hostnames stay stable, terminates a wildcard cert
    `*.192.168.1.27.nip.io` on :443, also serves :80, and sets `allowedRoutes.namespaces.from: All`
    (lines 38-46) so any namespace can attach. The cert is a cert-manager `Certificate` in the same
    file.
  - Every app contributes an HTTPRoute pointing back at it via `parentRefs: [{name: shared, namespace:
    gateway}]`. Examples: `platform/argocd/httproute.yaml` (`argocd.192.168.1.27.nip.io` →
    `argocd-server:80`), `platform/longhorn/manifests/httproute.yaml` (→ `longhorn-frontend:80`),
    `platform/minio/manifests/httproute.yaml` (→ `minio-console:9001`),
    `platform/goldilocks/httproute.yaml` (→ `goldilocks-dashboard:80`). Each carries the annotation
    `argocd.argoproj.io/ignore-healthcheck: "true"` — that's the fix from commit `7b6973a`: the
    Gateway only arrives at sync-wave 3, so routes must not gate earlier ArgoCD waves on health.
  - **The TLSRoute saga** (`bootstrap/00-gateway-api-prep.sh` + `docs/talos-gotchas.md` #3): Cilium
    1.19's Gateway controller indexes `TLSRoute` at **`v1alpha2`**, and with Gateway API enabled the
    *agents* refuse to start unless the TLSRoute CRD *exists*. But Gateway API v1.5 graduated TLSRoute
    to `v1` (with `v1alpha2` defined but `served: false`) and ships a `safe-upgrades`
    ValidatingAdmissionPolicy that blocks "downgrading" CRDs. The script's fix: install the standard
    CRDs, delete the `safe-upgrades` VAP + binding, then flip `v1alpha2` to `served: true` on the
    existing TLSRoute CRD (or, on older Gateway API, install the v1alpha2 CRD from release v1.3.0).
- **See it live:**
  ```
  export KUBECONFIG=$PWD/terraform/.kubeconfig
  kubectl -n gateway get gateway shared -o wide              # PROGRAMMED=True, ADDRESS=192.168.1.27
  kubectl -n gateway describe gateway shared | sed -n '/Listeners/,$p' | head -30
  kubectl -n argocd describe httproute argocd                # Parents -> Accepted=True, ResolvedRefs=True
  # the saga's end state — v1alpha2 served so Cilium's agent is happy:
  kubectl get crd tlsroutes.gateway.networking.k8s.io -o jsonpath='{range .spec.versions[*]}{.name}={.served}{"\n"}{end}'
  ```
  Look for: Gateway `PROGRAMMED=True`; each HTTPRoute's status condition `Accepted=True` and
  `ResolvedRefs=True`; the TLSRoute CRD reporting `v1=true` **and** `v1alpha2=true`.
- **Job relevance:** being able to draw the GatewayClass→Gateway→HTTPRoute hierarchy and explain
  `parentRefs`/`allowedRoutes` is exactly what "how does traffic get to a pod from outside?" is
  fishing for. The TLSRoute saga is a great "tell me about a hard bug" story: CRD version skew between
  an implementation and the API, plus an admission policy fighting your fix. Maps to **CKAD**.
- **Learn it:** gateway-api.sigs.k8s.io → "Guides / Simple Gateway", "HTTP routing", and "TLS"
  (terminate vs passthrough). For the cross-namespace bit: same site, "ReferenceGrant".

### The Envoy data plane — the proxy that actually moves and inspects the bytes

- **What it is / mental model:** A Gateway/Route is just *configuration* — declarative intent. Some
  real process has to open the socket on :443, accept the TCP connection, terminate TLS, parse the
  HTTP request, pick a backend, and proxy the bytes. That process is **Envoy**, a high-performance L7
  proxy. Mental model: the Gateway API is the building's floor plan and rulebook; Envoy is the actual
  security guard and elevator operator executing it in real time. Cilium translates your Gateway +
  HTTPRoutes into Envoy configuration and pushes it to the Envoy processes.
- **How it works:** the Cilium control plane reconciles Gateway API objects into Envoy's xDS config
  (clusters = backends, listeners = ports, routes = match rules). Envoy then handles every north-south
  HTTP request: TLS termination, host/path matching, load balancing across backend pods, retries,
  and L7 telemetry (which is what feeds Hubble's HTTP metrics). In this cluster Envoy runs as its own
  DaemonSet (`cilium-envoy`), separate from the agent, so proxy restarts don't disrupt the dataplane.
- **In THIS cluster:** there's a `cilium-envoy` pod on every node (you saw 6 of them). It's the data
  plane behind the `shared` Gateway and its `cilium-gateway-shared` LoadBalancer Service. See it live:
  ```
  export KUBECONFIG=$PWD/terraform/.kubeconfig
  kubectl -n kube-system get pods -l k8s-app=cilium-envoy -o wide      # one per node
  kubectl -n kube-system logs ds/cilium-envoy --tail=20               # access/health logs
  # generate a request and watch it traverse Envoy:
  curl -sk -o /dev/null -w '%{http_code}\n' https://argocd.192.168.1.27.nip.io
  ```
  Look for: a `cilium-envoy` pod per node; an HTTP `200`/`307` from the curl (proof Envoy terminated
  TLS and routed to `argocd-server`). Note `docs/talos-gotchas.md` #13's "residual": some requests to
  backends on the congested `nahida` host return Envoy `503 upstream connect timeout` — that's Envoy
  honestly reporting a backend it couldn't reach in time, a useful signal, not a config bug.
- **Job relevance:** "What's the difference between the control plane and data plane?" is a frequent
  systems-design question — Envoy is the canonical data-plane example (also the core of Istio,
  Contour, and many API gateways). Knowing Envoy *terminates TLS and load-balances at L7* (vs a
  Service which is L3/L4) shows you understand the OSI layers in practice. Supports **CKAD**/**CKS**.
- **Learn it:** envoyproxy.io → docs "Architecture overview" (listeners, clusters, filters) and
  "Life of a Request". You don't need to hand-write Envoy config — understand the concepts. Cilium's
  docs "Gateway API" page shows how it maps onto Envoy.

### CoreDNS — turning Service names into IPs (the cluster's phone book)

- **What it is / mental model:** Nothing inside the cluster talks to raw IPs by choice — code says
  `http://argocd-server` or `postgres.db.svc.cluster.local`. **CoreDNS** is the DNS server that
  resolves those names to ClusterIPs (and pod IPs). Mental model: it's the cluster's internal phone
  book, automatically kept in sync with every Service. Every pod is configured (via its
  `/etc/resolv.conf`, written by the kubelet) to ask CoreDNS first.
- **How it works:** CoreDNS runs as a Deployment, fronted by a Service named `kube-dns` at a
  well-known ClusterIP (`10.96.0.10` here). Its config is a `Corefile` (a plugin chain). The
  `kubernetes` plugin watches the API and answers `*.svc.cluster.local` from live Service/Endpoint
  data; anything else (e.g. `github.com`) is `forward`ed upstream. A Service `argocd-server` in
  namespace `argocd` resolves at `argocd-server.argocd.svc.cluster.local`, and search-domain magic
  lets a pod in the same namespace use the short name `argocd-server`.
- **In THIS cluster:** Talos ships CoreDNS as a core component (2 replicas here). It's the backbone of
  the in-cluster `192.168.1.27.nip.io` routing too — `nip.io` is a public wildcard DNS service that
  resolves `anything.192.168.1.27.nip.io` → `192.168.1.27`, so no DNS records to manage. See it live:
  ```
  export KUBECONFIG=$PWD/terraform/.kubeconfig
  kubectl -n kube-system get pods -l k8s-app=kube-dns        # 2 coredns pods Running
  kubectl -n kube-system get svc kube-dns                    # ClusterIP 10.96.0.10
  kubectl -n kube-system get cm coredns -o yaml | sed -n '/Corefile/,/}/p'   # the plugin chain
  # resolve a Service from inside the cluster:
  kubectl run dnstest --rm -it --image=busybox:1.36 --restart=Never -- \
    nslookup argocd-server.argocd.svc.cluster.local
  ```
  Look for: `kube-dns` ClusterIP `10.96.0.10`; the Corefile's `kubernetes cluster.local` block; the
  `nslookup` returning the ClusterIP of `argocd-server`.
- **Job relevance:** DNS is the #1 source of "it's always DNS" outages, so CKA explicitly tests it.
  Expect: "how does a pod resolve a Service name?", "what's the FQDN format
  (`<svc>.<ns>.svc.cluster.local`)?", "how do you debug DNS in-cluster?" (run a debug pod, check
  `/etc/resolv.conf`, query `kube-dns`). Maps to **CKA** (Services & Networking, plus the troubleshoot
  domain).
- **Learn it:** kubernetes.io → "DNS for Services and Pods" (memorize the FQDN/search-domain rules)
  and "Debugging DNS Resolution". For CoreDNS internals: coredns.io → "Manual / Corefile" and the
  `kubernetes` plugin page.

### The VXLAN overlay + the MTU 1450 lesson — the encapsulation, and the 50 bytes that broke everything

- **What it is / mental model:** Pods on different nodes have IPs (`10.244.x.y`) that the physical LAN
  (`192.168.1.0/24`) knows nothing about. An **overlay network** solves this by wrapping each
  pod-to-pod packet inside a normal node-to-node packet so it can ride the real network, then
  unwrapping it on the far side. Cilium's default overlay is **VXLAN** (Virtual Extensible LAN), which
  encapsulates the inner Ethernet frame in a UDP packet (port 8472). Mental model: shipping a letter
  (the pod packet) inside a bigger courier envelope (the VXLAN/UDP wrapper) addressed node-to-node;
  the courier network never reads the inner letter.
- **How it works:** the VXLAN wrapper adds **~50 bytes** of headers (outer Ethernet + IP + UDP +
  VXLAN). **MTU** (Maximum Transmission Unit) is the biggest packet a link will carry — typically
  **1500** bytes on Ethernet. If a pod thinks its MTU is 1500 and sends a full 1500-byte packet,
  adding the 50-byte VXLAN header makes **1550** bytes on the wire — too big for the 1500 link. With
  the "don't fragment" bit set, the switch silently **drops** it. The fix: tell pods their MTU is
  **1450** (1500 − 50) so the encapsulated packet fits exactly in 1500.
- **The lesson (the single best war story in this repo):** `docs/talos-gotchas.md` #12 — Cilium ran
  VXLAN but its MTU auto-detection left the pod `veth` and `cilium_vxlan` at **1500**, same as the
  underlay. Result: **small** packets (pings, DNS, tiny HTTP) passed; **large** ones (image layers,
  Postgres `pg_basebackup`, bulk query responses) vanished. This presented as ~5 *different* failures
  — registry pulls failing cross-node, CNPG replicas hanging at "join", Argo Rollouts canary aborting
  with "no route to host", the API readiness probe flapping. One root cause, five red herrings. The
  diagnosis was `cat /sys/class/net/eth0/mtu` inside a pod showing 1500. The fix: pin `MTU: 1450`
  (now `platform/cilium/values.yaml:4`) **and recreate existing pods**, because a pod keeps its old
  `veth` MTU until it's respawned. Golden heuristic: **"small requests work but big ones hang across
  nodes" → check pod MTU before anything else.**
- **In THIS cluster:** `platform/cilium/values.yaml:4` is `MTU: 1450` with the inline comment
  explaining the 50-byte VXLAN overhead. See it live:
  ```
  export KUBECONFIG=$PWD/terraform/.kubeconfig
  # what MTU do pods actually have?
  POD=$(kubectl -n kube-system get pod -l k8s-app=hubble-relay -o jsonpath='{.items[0].metadata.name}')
  kubectl -n kube-system exec "$POD" -- cat /sys/class/net/eth0/mtu          # -> 1450
  # confirm tunnel mode + the vxlan device MTU on a node:
  kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg status | grep -i -A1 'Routing\|Tunnel'
  ```
  Look for: pod `eth0` MTU **1450** (not 1500); Cilium reporting tunnel/VXLAN routing. If you ever see
  1500 here, you've reproduced the gotcha.
- **Job relevance:** MTU/overlay is a classic senior-level networking interview filter precisely
  because it presents so deceptively. "Large transfers hang but pings work between nodes — what's your
  hypothesis?" The expected answer is *MTU/fragmentation on an overlay*. Knowing VXLAN's ~50-byte
  overhead and the 1500→1450 math marks you as someone who's debugged real clusters. Supports **CKA**
  troubleshooting.
- **Learn it:** cilium.io → docs "Routing" (encapsulation/tunnel vs native) and "MTU". For the
  protocol: search "VXLAN RFC 7348" for the header layout. General concept: search "Path MTU
  Discovery" and "MTU black hole".

## Hands-on lab (on YOUR cluster)

Run this once per shell:

```
export KUBECONFIG=$PWD/terraform/.kubeconfig
```

All steps are read-only or clearly reversible.

**1. Prove there is no kube-proxy, and that Cilium does its job.**
```
kubectl -n kube-system get ds kube-proxy          # expect: Error ... "kube-proxy" not found
kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg status | grep -i KubeProxyReplacement
kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg service list | head
```
Success: no kube-proxy DaemonSet; `KubeProxyReplacement: True`; a service list mapping ClusterIP
frontends (e.g. `10.96.0.10:53` = DNS) to pod backends — Cilium *is* the Service load balancer.

**2. Watch the full north-south path with a single curl.** Pick any app hostname from
`kubectl get httproute -A` and hit it:
```
curl -skv https://argocd.192.168.1.27.nip.io 2>&1 | grep -E 'Server certificate|subject:|< HTTP/'
```
Success: TLS is terminated by Envoy (you'll see the `*.192.168.1.27.nip.io` certificate) and you get
an HTTP status line (e.g. `307`/`200`). You just exercised: ARP (L2 announce) → Gateway/Envoy (TLS +
route) → Service → pod.

**3. Find out which node is currently announcing the Gateway VIP.**
```
kubectl get ciliumloadbalancerippool homelab-pool          # IPS AVAILABLE
kubectl -n kube-system get lease | grep -i l2announce
```
Success: the pool shows `IPS AVAILABLE=4` (the Gateway took one of five). The L2 announcement lease's
holder is the `cilium` agent on `worker-1` — exactly the node pinned in
`platform/cilium/manifests/lb-ipam.yaml`. (Optional reversible experiment, only if you want to watch
failover: `kubectl -n kube-system delete lease <the-l2announce-lease>` forces a clean re-election;
because the policy `nodeSelector` pins `worker-1`, it re-elects worker-1 within ~20s — per gotcha #13.)

**4. Confirm the MTU is 1450 (the gotcha #12 check) and feel why it matters.**
```
POD=$(kubectl -n kube-system get pod -l k8s-app=hubble-relay -o jsonpath='{.items[0].metadata.name}')
kubectl -n kube-system exec "$POD" -- cat /sys/class/net/eth0/mtu
```
Success: prints `1450`. That single number is the difference between this cluster working and silently
dropping every image pull and DB backup. If it ever shows 1500, you've found the bug from the gotchas
log.

**5. Trace DNS resolution from inside the cluster.**
```
kubectl run dnstest --rm -it --image=busybox:1.36 --restart=Never -- \
  nslookup argocd-server.argocd.svc.cluster.local
```
Success: CoreDNS (server `10.96.0.10`) returns the ClusterIP of `argocd-server`. The `--rm` deletes
the test pod on exit. Bonus: change the query to `kubernetes.default.svc.cluster.local` and you'll get
the API server's ClusterIP.

**6. See the network as flows in Hubble.** Open the UI in a browser (it has its own HTTPRoute):
```
open https://hubble.192.168.1.27.nip.io
```
Then pick the `argocd` or `kubeshowcase` namespace and watch the live service map. Success: arrows
between workloads, with a flows table you can filter to `Dropped` verdict — that's the panel you'd
live in when debugging "A can't reach B." (No browser? `cilium hubble port-forward &` then
`hubble observe --last 20` if you install the `hubble` CLI.)

## Check yourself

1. **Why do Talos nodes report `NotReady` before Cilium is installed?**
   The CNI isn't present yet, so the kubelet can't set up pod networking — that's why this cluster
   installs Talos with `cni: none` and Cilium at sync-wave 0.
2. **What does `kubeProxyReplacement: true` change, and why does this cluster point Cilium at
   `localhost:7445`?**
   Cilium implements Service load balancing in eBPF so no kube-proxy runs; `localhost:7445` is Talos
   **KubePrism**, an on-node API-server load balancer that breaks the chicken-and-egg of needing a
   Service to reach the API before Cilium has programmed Services.
3. **Name the three Service types and the one fact that distinguishes each.**
   ClusterIP (internal-only VIP), NodePort (a high port 30000-32767 on every node), LoadBalancer (an
   external IP — here supplied by Cilium LB-IPAM, since there's no cloud).
4. **On bare metal, what two things must happen for a `LoadBalancer` Service to get a *reachable*
   IP, and what must you never run alongside Cilium's L2?**
   LB-IPAM assigns an IP from a pool; an L2 announcement makes a node answer ARP for it. Never run
   MetalLB at the same time — both answer ARP and fight over the VIP.
5. **How does an `HTTPRoute` connect to the `shared` Gateway, and who's allowed to attach?**
   Via `parentRefs: [{name: shared, namespace: gateway}]`; the Gateway sets
   `allowedRoutes.namespaces.from: All`, so any namespace may attach.
6. **What's the difference between a Service and Envoy in this stack (which OSI layers)?**
   A Service load-balances at L3/L4 (IP/port, no payload inspection); Envoy is the L7 data plane that
   terminates TLS and routes on HTTP host/path before forwarding to a Service.
7. **A pod resolves the name `grafana` but code in another namespace needs the full name — what is
   it, and who answers?**
   `grafana.<namespace>.svc.cluster.local`, answered by CoreDNS via the `kube-dns` Service at
   `10.96.0.10`.
8. **Cross-node, small requests work but large transfers hang. First hypothesis and the one command
   to check?**
   MTU mismatch on the VXLAN overlay (50-byte header); check pod MTU with
   `kubectl exec <pod> -- cat /sys/class/net/eth0/mtu` — it must be 1450, not 1500.

## Where this fits in the path

Do **Module 1 (Talos + cluster bootstrap)** first so `cni: none`, KubePrism, and immutable-OS
constraints make sense; after this, go to the **Ingress security / cert-manager + TLS** and **Network
Policy (CiliumNetworkPolicy / CKS)** modules — they build directly on the Gateway, Envoy, and Cilium
foundations laid here.
