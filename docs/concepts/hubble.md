# Hubble
> Cilium's built-in flow recorder — turns the invisible network into a readable, identity-aware log for "why can't A reach B?".

**What it is.** Hubble is [[cilium|Cilium]]'s network observability layer. Because Cilium already sees every packet in [[ebpf|eBPF]], it can cheaply *record* each flow — who talked to whom, on what port, allowed or dropped, even HTTP method/status with L7 visibility. Mental model: `tcpdump` shows raw packets on one interface; Hubble is a cluster-wide flow recorder with Kubernetes identities already attached — "pod `argocd-server` → Service `kube-dns` UDP/53, forwarded" instead of "10.244.2.103 → 10.96.0.10".

**How it works.** Each `cilium-agent` exposes a local Hubble server reading its node's eBPF flow events. **hubble-relay** aggregates all nodes into one cluster-wide stream; **hubble-ui** draws a live service map; the `hubble observe` CLI greps flows. Cilium also exports Hubble **metrics** (dns/drop/tcp/flow/http) to [[prometheus|Prometheus]], feeding [[observability-pillars|observability]] dashboards.

**In this cluster.**
- Enabled in `platform/cilium/values.yaml` (`hubble.enabled`, `relay.enabled`, `ui.enabled`, plus a metrics block with `httpV2` exemplars). UI exposed at `hubble.192.168.1.27.nip.io` via an HTTPRoute in `kube-system`.
- `kubectl -n kube-system get pods | grep -E 'hubble-relay|hubble-ui'` — both `Running`; open `https://hubble.192.168.1.27.nip.io` for the service map (filter to `DROPPED` to find bugs).

**See also:** [[cilium]] · [[ebpf]] · [[observability-pillars]] · [[prometheus]] · [[gateway-api]] &nbsp; **Deep dive:** [[02-networking]]
