# Talos Gotchas Log — what we ACTUALLY hit building this

Every entry below happened for real during the build (2026-06-12), with the diagnosis path.

## 1. Wrong default gateway ate the install (the big one)
**Symptom:** all 6 nodes stuck in `installing` stage forever; `talosctl dmesg` showed the
installer image pull from `factory.talos.dev` failing with `connect: no route to host`,
while DNS resolution *worked* (Pi-hole is on-subnet — no gateway needed).
**Cause:** machine configs assumed gateway `192.168.1.1`; this LAN's gateway is `192.168.1.254`
(confirmed via Proxmox `/nodes/<n>/network` → `vmbr0 gw=192.168.1.254`).
**Lesson:** on-subnet traffic masking a broken default route is sneaky — DNS resolving while
HTTPS fails points at routing, not DNS. Also: a failed install leaves `/dev/sda` EMPTY and the
node falls back to the ISO's maintenance mode after reboot (check `talosctl get discoveredvolumes --insecure`).

## 2. Talos 1.13 multi-doc `HostnameConfig` vs `machine.network.hostname`
**Symptom:** `apply-config` rejected with `static hostname is already set in v1alpha1 config`.
**Cause:** `talosctl gen config` (1.13) now emits a separate `HostnameConfig` document with
`auto: stable`; patching `machine.network.hostname` conflicts with it.
**Fix:** per-node patches delete the document (`kind: HostnameConfig` + `$patch: delete`)
and set the classic v1alpha1 hostname. See `talos/patches/nodes/*.yaml`.

## 3. Cilium 1.19 vs Gateway API v1.5 TLSRoute (operator AND agent disagree)
**Symptom #1:** cilium-operator crashloop: `failed to setup field indexer
"backendServiceTLSRouteIndex": no matches for kind "TLSRoute" in version
"gateway.networking.k8s.io/v1alpha2"`.
**Cause:** gateway-api v1.5 standard channel graduated TLSRoute to `v1`; Cilium 1.19 still
indexes `v1alpha2`. A CRD present at the wrong version is FATAL even though TLSRoute is "optional".
**Symptom #2:** after deleting the CRD, the operator recovered but the *agents* hung on
`Still waiting for Cilium Operator to register CRDs: crd:tlsroutes...` — with Gateway API
enabled, agents require the CRD to EXIST.
**Symptom #3:** installing the old v1alpha2 CRD was denied by gateway-api v1.5's
`safe-upgrades` ValidatingAdmissionPolicy (downgrade protection). Deleting the VAP raced its
own admission cache — the first apply after deletion still got denied; second apply worked.
**Fix (codified in `bootstrap/01-bootstrap-core.sh`):** delete the `safe-upgrades` VAP+binding,
apply TLSRoute v1alpha2 from gateway-api v1.3.0, restart cilium.

## 4. Worker `apid` port closed ≠ broken worker
**Symptom:** workers invisible on :50000 after config apply; panic instinct says reinstall.
**Cause:** worker apid serves only after getting certs from `trustd` on the control plane —
which can't issue until etcd is bootstrapped. Pre-bootstrap this is NORMAL.
**Lesson:** verify via Proxmox guest agent (`qemu-guest-agent` extension) — it showed the
workers alive with correct static IPs while :50000 was closed.

## 5. `bootstrap is not available yet`
`talosctl bootstrap` right after apply-config fails with FailedPrecondition until etcd's
service reaches the waiting state. Retry loop required (~2 min after first boot from disk).

## 6. ghcr.io push denied — OAuth token scopes
The gh CLI's keychain token (`gho_…`) pushes Git fine but lacks `write:packages`; ghcr.io
rejects image pushes with `denied: permission_denied`. Worked around with an in-cluster
registry (worker-1 hostPort `.23`, Talos `registries.mirrors` entry pointing at plain HTTP) + `crane push`
(no Docker daemon insecure-registry config needed on the workstation).

## 7. Don't pipe `helm --wait` into `head`
Self-inflicted: `helm upgrade --wait | head -30` → SIGPIPE killed helm mid-install, leaving
the release in `pending-install` with hook resources half-created. Recovery: delete the
`sh.helm.release.v1.<name>.v1` secret and re-run. (Also the original hang: chart-repo
download on first run is slow; pre-`helm repo update` in scripts.)

## 8. Pre-empted (didn't bite us, by design)
- Longhorn needed `iscsi-tools` + `util-linux-tools` extensions → baked into the factory image.
- NotReady nodes pre-CNI → expected with `cni: none`.
- kube-proxy-free Cilium → `k8sServiceHost: localhost:7445` (KubePrism).
- MetalLB vs Cilium L2 ARP fight → MetalLB never installed.
- VPA/HPA conflict → VPA targets only the frontend (HPA owns the API, KEDA owns the worker).
- CNPG self-manages resources → excluded from VPA.
- etcd quorum → chaos drill only ever kills ONE control-plane node.

## 9. Longhorn's helm pre-upgrade hook deadlocks ArgoCD app-of-apps
**Symptom:** `longhorn` app stuck `OutOfSync/Missing`, hook Job `longhorn-pre-upgrade` failing
with `serviceaccount "longhorn-service-account" not found` — and the ROOT app stuck
"waiting for healthy state of Application/longhorn", which meant the values fix committed to
Git could not propagate (root applies child Application specs, but root was blocked on the
child it needed to fix). Classic GitOps deadlock.
**Fix:** `preUpgradeChecker.jobEnabled: false` (Longhorn's documented setting for ArgoCD/Flux),
applied ONCE manually with `kubectl patch app longhorn` to break the cycle; Git already has it
for all future syncs. Lesson: helm lifecycle hooks and Argo CD sync waves are different
machines — disable chart hooks that assume `helm upgrade` semantics.

## 10. App-of-apps deadlock: editing a child Application's helm valuesObject
**Symptom:** bumped `prometheus-adapter`'s memory limit in its Application manifest (it was
OOMKilling at 128Mi), committed + pushed, hard-refreshed, restarted repo-server+redis,
force-synced — and the live Deployment STUBBORNLY stayed at the old 128Mi. ArgoCD reported
`Synced` the whole time.
**Cause:** the repo-server renders a Helm app using the **live `Application` object's**
`spec.sources[].helm.valuesObject` — NOT the Application YAML in Git directly. That live object
is itself reconciled by the **root** app-of-apps. Root was stuck `Progressing`, gated on the
Observe tier (incl. prometheus-adapter) reaching `Healthy` before it would apply the next
state. So: root won't push the fix until the child is healthy; the child can't be healthy
without the fix. Deadlock. (Compounded by a stale root *operation* that predated the commit.)
**Fix:** terminate the stale root operation (`kubectl patch app root --type json -p
'[{"op":"remove","path":"/operation"}]'`), hard-refresh root, start a fresh root sync — that
re-applies every child Application spec (now 512Mi) to the live objects. THEN sync the child.
Live Deployment finally rendered 512Mi and went healthy.
**Lesson:** when a Helm-via-ArgoCD app ignores a values change, check the *live Application's*
valuesObject, not just Git. If they differ, the app-of-apps parent hasn't propagated — fix the
parent, not the child.

## 11. Undersized control-plane RAM → etcd page-cache thrash → cluster-wide outage
**Symptom (the big one, ~hour 13):** the whole cluster became unreachable — VIP `192.168.1.19`
down, `kubectl` got `TLS handshake timeout` against every CP node directly, `talosctl etcd`
hung. Proxmox showed CP hosts at **load 34–68** but with **low CPU and ~73% iowait**, and the
guilty VM (`cp-3`) reading a sustained **~300 MB/s** from disk while writing ~nothing.
**Cause:** the CP VMs were provisioned at **2.5–3 GB RAM**. As the Observe tier landed
(kube-prometheus-stack's many CRs, Longhorn volume/replica/engine objects, ServiceMonitors),
the etcd DB + apiserver watch caches grew until the node ran out of RAM (`MemAvailable` ~260 MB).
etcd's bbolt store is **mmap'd**; under memory pressure the kernel evicts its pages and re-faults
them from disk on every access → a self-sustaining read storm at disk speed. etcd fsync/heartbeat
then misses its deadlines → leader elections fail → apiserver can't serve → cluster down. Talos's
OOMController was SIGKILLing besteffort pods in a loop the whole time. It ran fine for ~12 h
because the crash-looping observability pods (no MinIO buckets yet) had done **zero** I/O until
the buckets were created — that was the straw.
**Diagnosis path:** Proxmox per-VM `rrddata` showed cp-3 at 300 MB/s read while the *existing
k0s* VMs were idle (0–2 MB/s) — proving it was our etcd, not the neighbours. `talosctl dmesg`
confirmed repeated `OOMController ... Sending SIGKILL`.
**Fix:** bump CP RAM (cp-3 2.5→8 GB, cp-1 3→6 GB, cp-2 2.5→8 GB) via Proxmox `config memory=`,
**rolling, worst-node-first**, so etcd never loses quorum (always 2/3 up). cp-3 alone going to
8 GB dropped nahida's host load 68→19 instantly. Also reduced steady-state load: Longhorn
replicas 2→1, Prometheus retention 2d→12h.
**Lesson:** a Talos control-plane node running etcd for a CRD-heavy cluster needs real RAM
headroom — **8 GB**, not 2.5. "MemAvailable" on a CP must stay comfortably above the etcd DB
size or the mmap thrash will take the whole cluster down, and it presents as *disk* I/O, not
an obvious OOM. Size CP nodes for the object count, not just the pod count (which is ~zero on a
tainted CP).

## 12. Cilium VXLAN MTU left at 1500 → all large cross-node transfers silently dropped
**Symptom (the subtle killer behind a dozen red herrings):** image pulls from the in-cluster
registry failed cross-node ("not found"/timeout) while small catalog/tag queries succeeded;
CNPG replica `pg_basebackup` hung forever at "join"; Argo Rollouts canary analysis aborted with
"no route to host" to Prometheus; the API's readiness probe flapped 0/1↔1/1. Each looked like a
different problem (registry, Longhorn, Postgres, Rollouts, DNS) and sent me chasing LB-IPAM,
hostPort, node placement, and host load for hours.
**Cause:** Cilium ran in **VXLAN tunnel mode** but its MTU auto-detection left the pod veth and
`cilium_vxlan` at **1500** — the same as the underlay. VXLAN adds a 50-byte header, so any pod
packet ≥1450 bytes becomes ≥1500 on the wire and is dropped (DF) on the 1500 physical link.
Small packets (pings, DNS, tiny HTTP) pass; large ones (image layers, DB base-backups, bulk
query responses) vanish. Classic "works for small, hangs for large" MTU black hole.
**Diagnosis:** `kubectl exec <pod> -- cat /sys/class/net/eth0/mtu` → **1500** (should be 1450 on
VXLAN). `talosctl get links` confirmed `cilium_vxlan mtu=1500` on a 1500 `ens18`.
**Fix:** set Cilium `MTU: 1450` (helm value) — or patch `cilium-config` `mtu: "1450"` + restart
the `cilium` DaemonSet — then **recreate existing pods** (they keep their old veth MTU until
respawned). Fresh pods came up at 1450 and every cross-node large transfer started working:
registry pulls, CNPG replication, Rollouts analysis, stable API readiness. **This was the single
root cause masquerading as ~5 separate failures.**
**Lesson:** on Talos + Cilium VXLAN over a plain 1500 LAN, pin `MTU: 1450` from day one. When
"small requests work but big ones hang" across nodes, check pod MTU before anything else.
