# Gateway API
> The modern, role-split successor to Ingress for routing outside traffic in — portable, multi-protocol, annotation-free.

**What it is.** **Ingress** was Kubernetes' original "let HTTP in" object, but it was thin: anything beyond hostname/path needed vendor-specific annotations, with no clean split between infra and app teams. The **Gateway API** is the successor — a richer, portable, *role-oriented* set of resources. Mental model: Ingress is one overloaded form everyone scribbles annotations on; Gateway API is a proper org chart. The infra team owns the **GatewayClass** (which implementation) and **Gateway** (the listener + TLS); each app team owns its own **HTTPRoute** attaching via `parentRefs`. It's also protocol-aware (HTTP, TLS, gRPC, TCP), not HTTP-only.

**How it works.** Three layered resources — GatewayClass → Gateway → HTTPRoute — implemented by a controller ([[cilium|Cilium]] here, which compiles them into Envoy config). A Route lists `parentRefs` to a Gateway (possibly cross-namespace, allowed via `allowedRoutes`); the Gateway declares listeners; the Route binds by hostname/port. The controller then programs Envoy to terminate TLS and route each hostname to the right [[service|Service]].

**In this cluster.**
- One shared Gateway, many HTTPRoutes. `platform/gateway/gateway.yaml` defines `shared` (`gatewayClassName: cilium`), pinned to `192.168.1.27` via `lbipam.cilium.io/ips`, terminating wildcard cert `*.192.168.1.27.nip.io` ([[cert-manager]]). Routes use `argocd.argoproj.io/ignore-healthcheck` so they don't gate earlier [[sync-waves|sync-waves]]. CRDs installed in `bootstrap/00-gateway-api-prep.sh`.
- `kubectl get gatewayclass` → `cilium` `ACCEPTED=True`; `kubectl get ingress -A` → empty (this cluster has none).

**See also:** [[cilium]] · [[service]] · [[lb-ipam]] · [[cert-manager]] · [[argo-cd]] · [[sync-waves]] &nbsp; **Deep dive:** [[02-networking]]
See [[OPERATIONS]].
