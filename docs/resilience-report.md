# Resilience Report — KubeShowcase

This is not a list of *scripted* drills that went smoothly. During the build the cluster hit
**five genuine production incidents** on real (shared, oversubscribed) homelab hardware, each
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

## Incident 5 — single-replica volume fault → crash-loop cascade (and an operator misstep)
**Severity:** observability tier down (~20 min). **Root cause:** a node I/O-wedge faulted the
single replica of two Longhorn volumes; an over-aggressive manual remediation then amplified it.

**Timeline**
- `nahida` (host of 3 of our 6 VMs + the co-tenant k0s worker) drifted into sustained **disk
  iowait** — host loadavg **~30 on worker-3's guest with the VM using only ~2.6 of 6 cores**
  (high load, low CPU = I/O wait, not steal; the host itself sat at loadavg ~80 with 4.8 GB of
  33 GB free). `worker-3`'s kubelet/cilium-agent could no longer service requests in time:
  `Cilium API client timeout` → **`429 putEndpointIdTooManyRequests`** → pod sandboxes failed to
  create → kubelet retried → more load. A self-amplifying loop.
- With **`defaultReplicaCount: 1`** (an Incident-1 I/O-budget decision), the lone replica of the
  `prometheus` TSDB and `loki` storage volumes lived on the wedged node and went **`faulted`**.
  `prometheus-0` crash-looped (`/prometheus/queries.active: input/output error`); `loki-0` hung
  `ContainerCreating`.

**The misstep (documented honestly).** To "drain the noise" I mass-deleted ~15 crash-looping
pods. On an **I/O-wedged** node this backfired: deletion itself needs kubelet I/O the node can't
spare, so the pods stuck in **`Terminating`** (zombies), their controllers spun recreating
replacements that piled up **`Pending`** on the memory-full `worker-2` (5.4/5.4 GB), and the
termination/image-pull/sandbox storm drove the `nahida` host loadavg **138 → 143**. I made it
worse before I made it better.

**Recovery (what actually worked)**
1. **Undid** the reflexive `cordon worker-3` — wrong call, because the only other nahida worker
   was memory-full, so cordoning just stranded pods `Pending`.
2. **Force-cleared the zombie `Terminating` pods** (`--grace-period=0 --force`) to stop the
   control-plane reconcile churn → host loadavg dropped **142 → 78** within ~90 s.
3. Let the host **quiesce hands-off** (no further pokes) — `loki-0` self-healed once CNI calls
   stopped timing out.
4. **Recreated only the genuinely-faulted volumes** (`prometheus`, `loki` — both hold *regenerable*
   history, so a fresh PVC costs nothing): delete pod + PVC, the StatefulSet/operator reprovisions
   a fresh Longhorn volume on a healthy node. Crash loops stopped.

**Lessons (codified in gotcha #14)**
- On an **I/O-saturated** node, *do not mass-delete pods*. Deletion is not free — it consumes the
  exact resource the node lacks. Stop adding work, let controllers quiesce, then surgically
  recreate only what's truly broken.
- **`cordon` is not a relief valve when the rest of the tier has no headroom** — it converts
  `CrashLoopBackOff` into `Pending`, not into `Running`.
- **`replicaCount: 1` means any node I/O-wedge faults that node's volumes.** Acceptable for
  regenerable observability data (metrics/logs); the app's Postgres is protected differently (CNPG
  + off-cluster backups, see [REBUILD.md](REBUILD.md)), not by Longhorn replication.

**Protected by:** the data that mattered was never on a single-replica Longhorn volume; the faulted
volumes were pure cache. ArgoCD self-heal reprovisioned the StatefulSet volumes from their
templates with zero manifest changes.

---

## The clean-room rebuild — reproducibility, proven (not just claimed)
After the co-tenant machines were powered off (freeing the hosts), the **entire cluster was torn
down and rebuilt from scratch via `terraform apply`** — 6 VMs deleted, fresh PKI, fresh etcd,
the whole platform reconciled by Argo CD from Git. This is the real test of "redeploy it as it
was," and it surfaced **seven latent reproducibility gaps** that a hand-built cluster had silently
papered over. Each is now fixed in Git, so the *next* `terraform apply` is clean:

| # | Gap (only bit on a true from-scratch build) | Fix |
|---|---|---|
| 1 | Maintenance-IP discovery hard-coded `ipv4_addresses[1][0]`; Talos exposes bond0/dummy0/… before ens18 | pick first non-loopback IPv4 dynamically (`talos.tf`) |
| 2 | Talos 1.13 "static hostname already set in v1alpha1 config" | add `HostnameConfig $patch: delete` to the TF node-patch template |
| 3 | ISO already on the datastore → `proxmox_download_file` errored | `overwrite_unmanaged = true` (`images.tf`) |
| 4 | Gateway-API prep ran before the VIP stabilised; TLSRoute now ships in gw-api ≥1.5 standard (v1) | wait-for-API loop; flip the existing CRD's `v1alpha2` to *served* instead of applying the old CRD |
| 5 | `node-exporter` rejected — `monitoring` ns inherited PSA `baseline` | `managedNamespaceMetadata` privileged (matches longhorn) — this had **stalled the whole app-of-apps sync wave** |
| 6 | **Spegel's `mirroredRegistries: []` (= mirror ALL) wrote a catch-all that hijacked the plain-HTTP in-cluster registry → `ErrImagePull`** | list only public registries + `prependExisting: true` + mirror the in-cluster registry as `http://` |
| 7 | `prometheus-adapter` OOMKilled at 512Mi once full observability (2d retention) was restored | limit → 1Gi |

**Plus a real failover *during* the rebuild:** under the deploy churn, CNPG's Postgres primary
moved to `ks-db-2` and the old replica diverged on its WAL timeline ("Refusing to restore future
timeline"). CNPG's own remediation handled it — deleting the diverged instance's PVC triggered an
automatic `pg_basebackup` re-clone from the new primary, back to 2/2. The app served HTTP 201s
throughout (writes went to the surviving primary).

**Outcome:** a fresh, **balanced** cluster (one CP + one worker per host), Longhorn at **2
replicas** across distinct hosts, full LGTM + security tiers Healthy, the demo app exercising
Postgres-HA / Redis-queue / KEDA scale-to-zero / HPA-custom-metrics — all from `terraform apply`
→ Argo CD → `03-finish.sh`. The reproducibility claim is now load-bearing.

---

## Engineering decisions forced by the hardware (documented deviations)
| Decision | Why | Where |
|---|---|---|
| CP RAM 2.5→8 GB | etcd page-cache thrash (Incident 1) | gotcha #11, README |
| Cilium `MTU: 1450` | VXLAN overhead (Incident 2) | gotcha #12, `platform/cilium/values.yaml` |
| Longhorn replicas 2→1 | halve write-amp on shared spinning disks | `apps/platform/longhorn.yaml` |
| Prometheus retention 2d→12h | TSDB compaction I/O | `apps/observability/kube-prometheus-stack.yaml` |
| Registry → hostPath + hostPort on `worker-1` (`.23`) | LB-IPAM/overlay too flaky under `nahida` load; physical LAN is robust | `platform/registry/registry.yaml`, gotcha #6 |
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
