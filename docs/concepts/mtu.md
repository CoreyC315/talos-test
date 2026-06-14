# MTU & VXLAN
> The encapsulation that carries pod traffic across nodes — and the 50 bytes that once silently broke every large transfer.

**What it is.** Pods on different nodes have IPs (`10.244.x.y`) the physical LAN (`192.168.1.0/24`) knows nothing about. An **overlay network** wraps each pod-to-pod packet inside a normal node-to-node packet so it can ride the real network, then unwraps it on the far side. [[cilium|Cilium]]'s default overlay is **VXLAN** (Virtual Extensible LAN), encapsulating the inner frame in a UDP packet (port 8472). Mental model: shipping a letter inside a bigger courier envelope addressed node-to-node — the courier never reads the inner letter. **MTU** (Maximum Transmission Unit) is the biggest packet a link will carry, typically **1500** bytes on Ethernet.

**How it works.** The VXLAN wrapper adds **~50 bytes** of headers. If a pod thinks its MTU is 1500 and sends a full 1500-byte packet, adding 50 bytes makes 1550 on the wire — too big for the 1500 link; with "don't fragment" set, the switch silently **drops** it. The fix: tell pods their MTU is **1450** (1500 − 50) so the encapsulated packet fits exactly. Symptom of getting this wrong: **small requests work, large ones hang across nodes** (image pulls, DB backups vanish).

**In this cluster.**
- `platform/cilium/values.yaml`: `MTU: 1450` with an inline comment on the 50-byte VXLAN overhead. Auto-detect once wrongly left pods at 1500 — the war story in `docs/talos-gotchas.md` #12 (fix requires recreating pods).
- `kubectl -n kube-system exec <pod> -- cat /sys/class/net/eth0/mtu` → must be `1450`, not `1500`.

**See also:** [[cilium]] · [[cni]] · [[service]] · [[ebpf]] · [[longhorn]] · [[cloudnative-pg]] &nbsp; **Deep dive:** [[02-networking]]
See [[OPERATIONS]].
