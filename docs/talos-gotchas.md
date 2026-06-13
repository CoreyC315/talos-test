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
registry (LB `.28`, Talos `registries.mirrors` entry pointing at plain HTTP) + `crane push`
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
