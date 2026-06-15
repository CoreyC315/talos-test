# Plan — Get the Media Stack Fully Operational on Talos

**Goal:** every media service running *and working together* on the Talos cluster (`kubeshowcase`):
the *arr stack + prowlarr, qbittorrent (VPN), and jellyfin (GPU), with the full pipeline wired
(request → search → download → import → library → playback).

**Current blocker:** aether is hung at POST (Vega reset bug) → worker-1 + cp-2 down. Phase 0 clears it.
Run the phases in order once aether is cold-booted.

---

## Phase 0 — Recover aether + cluster (prerequisite)
1. **(Corey, physical)** cold-power-cycle aether — full power OFF ~10s → ON. VMs auto-start (`onboot=1`).
   If it hangs at POST again → do the **vendor-reset** install (Phase 5) or temporarily detach the GPU to boot.
2. Verify host + cluster back:
   - aether pingable (`ping 192.168.1.100`); VMs 112/201/221/223 `running`.
   - `kubectl get nodes` → cp-2 + worker-1 `Ready`.
   - **Gateway IP live:** `curl -sk -o /dev/null -w '%{http_code}' https://komga.192.168.1.27.nip.io` ≠ `000`.
     Confirm the L2 SPOF fix is live: `kubectl get ciliuml2announcementpolicy l2-policy -o jsonpath='{.spec.nodeSelector.matchLabels}'` → `{"kubernetes.io/os":"linux"}` (not worker-1). If still worker-1, `kubectl apply -f platform/cilium/manifests/lb-ipam.yaml`.

## Phase 1 — Core stack health check (already migrated + running)
All on NFS config with real libraries; just confirm they survived and are reachable:
- `kubectl -n media get pods` → sonarr, radarr, komga, suwayomi, seerr, flaresolverr, prowlarr all `1/1`.
- Each reachable via `https://<app>.192.168.1.27.nip.io` (sonarr=385 series, radarr=81 movies expected).

## Phase 2 — qbittorrent (download client + VPN)
1. Bring up: `sed -i '' 's/^  replicas: 0.*/  replicas: 1/' workloads/qbittorrent/deployment.yaml` → commit → push → hard-refresh `qbittorrent` Argo app. (Fresh ProtonVPN key is already in the Talos secret.)
2. Verify VPN holds: gluetun `tun0 rx_bytes > 0`, `/v1/publicip/ip` populated, `/tmp/gluetun/forwarded_port` set, qbit `connection_status: connected`, **0 restarts/60s**.
3. If it flaps on a *stable* network → raise `HEALTH_VPN_DURATION_INITIAL` or try a different P2P server.

## Phase 3 — jellyfin (GPU + playback)
1. Verify GPU on worker-1: `talosctl ... ls /dev/dri` → `renderD128`; `dmesg | grep amdgpu` → firmware loaded, no fatal errors.
2. Get render-node GID (privileged probe pod on worker-1): `stat -c '%g' /dev/dri/renderD128`.
3. If GID ≠ 110, edit `workloads/jellyfin/deployment.yaml` `supplementalGroups: [44, <gid>]`.
4. Deploy: `git add workloads/jellyfin apps/media/jellyfin.yaml && git commit -m "jellyfin on Talos w/ GPU" && git push`. Argo creates ns `media-gpu` + deploys.
5. Verify: pod `1/1` on worker-1; `/config` = migrated 1.6 GB; reachable at `https://jellyfin.192.168.1.27.nip.io`; **VAAPI transcode** active (Dashboard → Playback, or play+transcode and watch logs for `radeonsi`/VAAPI).

## Phase 4 — End-to-end wiring (the stack actually works together)
1. **prowlarr → *arr:** prowlarr Settings → Apps → sonarr + radarr connected; indexers sync down (check sonarr/radarr Settings → Indexers populated).
2. ***arr → qbit:** sonarr/radarr Settings → Download Clients → qBittorrent test = green (`/api/v3/downloadclient/test` → 200).
3. **Pipeline smoke test:** add one show in sonarr (or request via seerr) → it searches (prowlarr) → grabs (qbit, over VPN) → completes → imports to `/data` (shared NFS) → appears in jellyfin → plays (GPU transcodes if the client needs it).
4. **seerr:** can browse + request → routes to sonarr/radarr.

## Phase 5 — Resilience, durable fixes, cleanup
- **vendor-reset** on the aether host (root): DKMS module + set GPU `reset_method=device_specific` + reboot. Makes Renoir GPU resets clean → no more host hangs on VM-to-VM GPU moves → also unblocks the GPU "switch button."
- **k0s `protonvpn-secret`:** patch with the same fresh key (from `wg-US-MI-1.conf`) so qbit is switch-ready on both clusters.
- **Cleanup:** delete NFS staging (~750 MB, `/volume1/appconfig/.staging`); drop the demo `switched-from-talos` prowlarr tag + orphan NAS test dirs.

## Later / optional (separate goals — not this plan)
- **Dual-cluster switchability:** repoint the k0s-side *arr apps to the same NFS config (like prowlarr) so the whole stack switches k0s↔talos; then the Phase-4 "switch button."
- **Deferred apps:** ollama/open-webui (AI), subgen/whisper, obsidian-sync, cbz-maker — bring over if wanted.

---

## Environment / key facts
- **Talos kubeconfig:** `KUBECONFIG=/Users/ccampbell/dev/talos-test/terraform/.kubeconfig`
- **talosconfig:** `/tmp/ks-talosconfig` (regen: `cd terraform && terraform output -raw talosconfig > /tmp/ks-talosconfig`); use `talosctl -n 192.168.1.23 -e 192.168.1.20 …`
- **k0s kubeconfig:** `KUBECONFIG=~/.kube/config` (context `homelab-cluster`)
- **Proxmox API:** aether `https://192.168.1.100:8006` (use raiden `.101`/nahida `.104` if aether down). Token: `~/dev/homelab-devops/terraform/credentials.auto.tfvars`.
- **Node↔VM:** worker-1=VM223 (GPU, aether), cp-2=VM221, k0s-worker=VM112, k0s-master=VM201 (all aether).
- **GPU:** Renoir iGPU `0000:04:00.0` (`1002:1638`, iommugroup 12) → VM223 via Proxmox PCI mapping `vega-igpu` (`hostpci0: mapping=vega-igpu,pcie=1`). worker-1 Talos schematic w/ amdgpu: `ef3dc12958d5bc90d2f5c06f37a8625b544244f6c564969fe239b00d7d3c9592` @ v1.13.4.
- **Fresh WG key file:** `/Users/ccampbell/Downloads/wg-US-MI-1.conf` (extract with `cut -d= -f2-`, not `sed`, since base64 ends in `=`).
- **Staged (uncommitted) jellyfin manifests:** `workloads/jellyfin/` + `apps/media/jellyfin.yaml`.

## Gotchas learned (→ talos-gotchas.md)
1. **Cilium L2 SPOF:** never pin `CiliumL2AnnouncementPolicy.nodeSelector` to one hostname — when it dies the LB IP goes dark with no failover. Use `kubernetes.io/os: linux`.
2. **AMD Renoir/Vega passthrough reset bug:** hard-stopping the VM holding the iGPU wedges it; next VM fails to start ("failed to reset PCI device"); a **warm** host reboot of a wedged GPU **hangs the host at POST**. Fix = vendor-reset; meanwhile graceful-shutdown the GPU VM and only ever **cold**-boot to reset it.
3. **Proxmox passthrough + non-root API token:** raw `hostpci0=0000:…` needs root; use a PCI **resource mapping** (token needs Mapping.Use) — mapping MUST include `iommugroup` + `subsystem-id` or VM start fails.
4. **Proxmox config API:** `PUT /qemu/{id}/config` is async — verify the change applied.
5. **ProtonVPN+gluetun:** reconnect storms rate-limit the WG key (rx=0, healthcheck i/o timeouts, ~6s restart loop). Fresh key clears it; prove it's the key (not the cluster) by cross-testing on both clusters.
