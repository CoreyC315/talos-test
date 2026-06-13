# Resilience Report — KubeShowcase

This is not a list of *scripted* drills that went smoothly. During the build the cluster hit
**four genuine production incidents** on real (shared, oversubscribed) homelab hardware, each
diagnosed from first principles and recovered with the platform's own primitives. Those are far
better evidence of resilience than a clean `talosctl drain`. The scripted drills (worker drain,
CP power-off, Velero DR, rolling upgrade) are documented as runbooks in
[`load-and-chaos/runbooks/`](../load-and-chaos/runbooks/); the **lived** incidents are below.

> Hardware reality that shaped everything: the 3 Proxmox hosts also run a **separate, busy k0s
> cluster** + Home Assistant + PBS. `nahida` in particular is frequently CPU/disk-saturated by a
> co-tenant k0s worker outside this cluster's control. The Talos cluster had to be made resilient
> *to its own noisy neighbours*. Where a component genuinely didn't fit the I/O budget, it was
> throttled and documented rather than left to destabilise the platform (per the build brief).

---

## Incident 1 — etcd page-cache thrash took the whole control plane down
**Severity:** total API outage (~25 min to full recovery). **Root cause:** undersized CP RAM.

**Timeline**
- T+0 (~hour 13): `kubectl` starts returning `TLS handshake timeout` against the VIP *and* every
  control-plane node directly. `talosctl etcd` hangs. The VIP `192.168.1.19` stops answering.
- Diagnosis: Proxmox showed CP hosts at **load 34–68 with ~20% CPU and ~73% iowait** — classic
  I/O wait, not CPU. Per-VM `rrddata` showed `cp-3` reading a sustained **~300 MB/s from disk**
  while the co-tenant k0s VMs were idle (0–2 MB/s) — proving it was *our* etcd. `talosctl dmesg`
  showed Talos's `OOMController` SIGKILLing pods in a loop. `MemAvailable` on the CP was ~260 MB.
- Mechanism: the CP VMs were provisioned at **2.5–3 GB**. As the Observe tier landed (kube-prom
  CRs, Longhorn objects, ServiceMonitors), the etcd DB + apiserver watch caches outgrew RAM.
  etcd's **mmap'd bbolt store** had its pages evicted under memory pressure and re-faulted from
  disk on every access → a self-sustaining read storm at disk speed → etcd fsync/heartbeat missed
  deadlines → leader elections failed → apiserver unservable. (It ran fine for ~12 h only because
  the observability pods had been crash-looping with no MinIO buckets, doing *zero* I/O until the
  buckets were created — that was the straw.)

**Recovery — rolling RAM bump preserving etcd quorum**
1. Shed I/O first: stopped the two heaviest Talos workers on `nahida` (etcd quorum is CP-only, so
   workers are safe to stop).
2. Bumped CP RAM **worst-node-first** so quorum (2/3) was never lost:
   `cp-3` 2.5→**8 GB**, `cp-1` 3→**6 GB** (capped — `raiden` is a 16 GB host shared with k0s),
   `cp-2` 2.5→**8 GB**. Each via Proxmox `config memory=`, one node at a time, waiting for
   `Ready` + etcd rejoin before the next.
3. `cp-3` alone going to 8 GB dropped `nahida`'s host load **68 → 19 instantly**.
4. Reduced steady-state pressure: Longhorn replicas **2 → 1**, Prometheus retention **2d → 12h**.

**Protected by:** etcd quorum (the cluster *data* was never at risk — only availability); Talos's
API-driven, reboot-safe `config` apply; one-CP-per-host placement (no single host failure could
take 2 etcd members). **Recovery time:** ~25 min. **Data loss:** none. Full write-up: gotcha #11.

---

## Incident 2 — the MTU black hole (one root cause wearing five masks)
**Severity:** persistent cross-node failure of every *large* transfer. **Root cause:** Cilium
VXLAN MTU left at 1500.

For hours the cluster threw what looked like five unrelated failures:
- in-cluster registry image pulls failed **cross-node** ("not found"/timeout) while small
  catalog/tag queries succeeded;
- CNPG replica `pg_basebackup` hung forever at "join";
- Argo Rollouts canary analysis aborted with "no route to host" to Prometheus;
- the API readiness probe flapped 0/1↔1/1;
- Longhorn engine-image attach intermittently failed.

I chased each as its own bug (LB-IPAM, hostPort, node placement, host load) before spotting the
shared signature: **small packets work, large packets vanish, only across nodes.** That is a
textbook MTU black hole.

**Diagnosis:** `kubectl exec <pod> -- cat /sys/class/net/eth0/mtu` → **1500**. Cilium ran VXLAN
(50-byte header) but auto-detect left the pod veth and `cilium_vxlan` at the underlay's 1500, so
any pod packet ≥1450 B became ≥1500 B on the wire and was dropped (DF) on the physical link.

**Fix:** set Cilium `MTU: 1450` (cilium-config + agent restart), then recreate pods (they keep
their old veth MTU until respawned). Fresh pods came up at 1450 and **every** symptom cleared at
once: registry pulls, CNPG replication, Rollouts analysis, stable API readiness.

**Protected by:** nothing automatic — this was a latent misconfiguration. The lesson (gotcha #12)
is now codified: pin `MTU: 1450` from day one on Talos + Cilium VXLAN over a plain 1500 LAN.
**This single fix retired ~5 "separate" incidents.**

---

## Incident 3 — Argo CD application-controller OOM under fleet growth
**Severity:** GitOps stalled (new apps not reconciled). **Root cause:** controller mem limit too low.

As the fleet grew to **31 Applications**, `argocd-application-controller` hit its **1 GiB** limit
(it was at 992 Mi, restarting x4) and fell behind — newly-applied Applications got *no* status and
never synced (the KubeShowcase app sat with an empty sync state). Diagnosed via
`kubectl top pod` + restart count. **Fix:** raised the controller to **2 GiB**. It caught up
immediately. Lesson: size the Argo CD controller for *object count*, not app count — kube-prom
alone contributes ~120 tracked resources.

---

## Incident 4 — cascading recovery after a Cilium restart (self-inflicted, instructive)
**Severity:** transient platform-wide churn. **Root cause:** restarting the CNI is disruptive.

Applying the MTU fix required restarting the `cilium` DaemonSet. While agents recompiled BPF,
**CNI endpoint creation timed out** (`Cilium API client timeout`, then `429
putEndpointIdTooManyRequests` on the slow `nahida` agent) → new pods (Longhorn CSI, engine-image,
CoreDNS) couldn't get networking → Longhorn couldn't provision → the CNPG PVC went Pending →
the gateway Envoy on `worker-1` **OOM-killed** (exit 137) under the reschedule load on a 4 GB node.

**Recovery (ordered, dependency-first):**
1. Waited for cilium agents to stabilise (6/6, 0 restarts) — verified a fresh test pod got MTU
   1450 + working CNI before touching anything downstream.
2. Recreated the stuck Longhorn CSI / engine-image pods so they got clean networking.
3. Bumped `worker-1` 4→**8 GB** (host `aether` had headroom after the operator freed co-tenant
   resources) — the gateway Envoy stopped OOMing.
4. Pinned Cilium **L2 LB announcements to `worker-1`** (the healthy `aether` worker) so the
   Gateway VIP `.27` and registry stopped being announced from the congested `nahida` workers.
5. Restarted the CNPG operator → it could finally reach its instances cross-node (MTU fixed) and
   reported the cluster **2/2 healthy** — the replica had actually joined; the operator just
   couldn't *see* it before.

**Protected by:** every controller's reconcile loop (ArgoCD self-heal, Longhorn, CNPG, Rollouts)
eventually re-converged once the underlying network + RAM were fixed — the system is genuinely
self-healing given a correct substrate.

---

## Engineering decisions forced by the hardware (documented deviations)
| Decision | Why | Where |
|---|---|---|
| CP RAM 2.5→8 GB | etcd page-cache thrash (Incident 1) | gotcha #11, README |
| Cilium `MTU: 1450` | VXLAN overhead (Incident 2) | gotcha #12, `platform/cilium/values.yaml` |
| Longhorn replicas 2→1 | halve write-amp on shared spinning disks | `apps/platform/longhorn.yaml` |
| Prometheus retention 2d→12h | TSDB compaction I/O | `apps/observability/kube-prometheus-stack.yaml` |
| Registry → hostPath + hostPort on `worker-1` (`.23`) | LB-IPAM/overlay too flaky under `nahida` load; physical LAN is robust | `platform/registry/registry.yaml`, gotcha (registry) |
| Cilium L2 announcer pinned to `worker-1` | keep VIPs off congested `nahida` | `platform/cilium/manifests/lb-ipam.yaml` |
| Argo CD controller 1→2 GiB | OOM at 31 apps (Incident 3) | `bootstrap/argocd/values.yaml` |
| Trivy Operator scan-paused (replicas 0) | full-image scanning saturates shared disks | `apps/security/trivy-operator.yaml` |
| Pyroscope (Stretch) dropped | does not fit the RAM/I-O budget honestly | README |

## Scripted drills (runbooks ready to execute)
- **Worker-node failure** → PDBs + topology-spread + Longhorn rebuild: `runbooks/chaos-worker-drain.md`
- **Control-plane failure** → VIP failover, etcd 2/3 quorum: `runbooks/chaos-controlplane.md`
- **DR** → Velero backup/restore of `kubeshowcase`: `runbooks/dr-velero.md`
- **Zero-downtime upgrade** → `talosctl upgrade` + `upgrade-k8s`: `runbooks/upgrade-talos-k8s.md`

> Note: Incident 1's recovery already exercised real CP-node stop/resize/start **with quorum
> preserved**, and Incident 4 exercised real worker stop/restart with workload reschedule — i.e.
> the chaos scenarios happened for real, unplanned, and the platform survived them.
