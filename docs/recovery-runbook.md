# Recovery Runbook — finish GPU jellyfin + qbit (after aether cold-boot)

**Status as of last session:** aether host hung at POST after a reboot (Vega iGPU reset bug), taking
worker-1 + cp-2 down. Most degradation cascades from that. Everything below is staged and waiting.

## Pre-req (Corey, physical)
**Cold-power-cycle aether** — full power OFF ~10 sec, then ON (NOT a warm reboot; that's what wedged
the GPU). VMs auto-start (`onboot=1`). If it hangs at POST *again* on the GPU → go to "vendor-reset"
at the bottom (the durable fix), or temporarily detach the GPU to boot.

## Environment / key facts
- **Talos kubeconfig:** `KUBECONFIG=/Users/ccampbell/dev/talos-test/terraform/.kubeconfig`
- **Talos talosconfig:** `/tmp/ks-talosconfig` (regen if missing: `cd terraform && terraform output -raw talosconfig > /tmp/ks-talosconfig`). Use `talosctl -n 192.168.1.23 -e 192.168.1.20 ...`
- **k0s kubeconfig:** `KUBECONFIG=~/.kube/config` (context `homelab-cluster`)
- **Proxmox API:** `https://192.168.1.100:8006` (aether) — if aether down, use raiden `192.168.1.101` or nahida `192.168.1.104`. Token in `~/dev/homelab-devops/terraform/credentials.auto.tfvars` (`terraform-prov@pve!terraform-token`).
- **Node ↔ VM:** worker-1=VM223 (GPU node, aether), cp-2=VM221, k0s-worker=VM112, k0s-master=VM201 — all on aether.
- **GPU:** AMD Renoir iGPU `0000:04:00.0` (`1002:1638`), iommugroup 12. Passed to VM223 via Proxmox PCI **resource mapping** `vega-igpu` → `hostpci0: mapping=vega-igpu,pcie=1`.
- **Talos schematic w/ amdgpu (worker-1 only):** `ef3dc12958d5bc90d2f5c06f37a8625b544244f6c564969fe239b00d7d3c9592` @ v1.13.4.
- **Fresh ProtonVPN WG key file:** `/Users/ccampbell/Downloads/wg-US-MI-1.conf` (extract value with `cut -d= -f2-`, NOT `sed 's/.*=//'` — the base64 key ends in `=`).

---

## Recovery steps (run in order)

### R1 — confirm host + cluster recovered
- aether pingable (`ping 192.168.1.100`); VMs 112/201/221/223 `running`.
- `kubectl get nodes` → cp-2 + worker-1 back `Ready`.
- **Gateway IP:** `curl -sk -o /dev/null -w '%{http_code}' https://komga.192.168.1.27.nip.io` → not `000`.
  - Check L2 announcer: `kubectl -n kube-system get lease cilium-l2announce-gateway-cilium-gateway-shared -o jsonpath='{.spec.holderIdentity}'` (should be a live node).
  - **Confirm the SPOF fix synced:** `kubectl get ciliuml2announcementpolicy l2-policy -o jsonpath='{.spec.nodeSelector.matchLabels}'` should be `{"kubernetes.io/os":"linux"}`, NOT `worker-1`. If still worker-1, the `cilium` Argo app didn't sync — `kubectl apply -f platform/cilium/manifests/lb-ipam.yaml` (git already has the fix, committed).

### R2 — verify GPU on worker-1
- `talosctl ... ls /dev/dri` → expect `card0` + `renderD128`.
- `talosctl ... read /proc/modules | grep amdgpu` → loaded; `talosctl ... dmesg | grep -i amdgpu` → firmware loaded, no fatal errors.
- **Get render-node GID** (privileged probe pod, nodeSelector worker-1, hostPath /dev/dri):
  `stat -c '%n %g' /dev/dri/renderD128` → note the group GID.

### R3 — deploy jellyfin (manifests already authored + validated, staged uncommitted)
- Files: `workloads/jellyfin/{storage,deployment,service,httproute}.yaml` + `apps/media/jellyfin.yaml`.
- **If render GID from R2 != 110**, edit `workloads/jellyfin/deployment.yaml` → `supplementalGroups: [44, <gid>]`. (If jellyfin runs as root, moot — but set it correctly anyway.)
- `git add workloads/jellyfin apps/media/jellyfin.yaml && git commit -m "jellyfin: deploy with GPU" && git push`
- Hard-refresh root app if needed; Argo creates ns `media-gpu` (privileged) + deploys.
- Verify: pod 1/1 on worker-1; `/config` = migrated 1.6 GB (jellyfin.db 35 MB); reachable at `https://jellyfin.192.168.1.27.nip.io`.
- **Verify VAAPI transcode:** jellyfin Dashboard → Playback → hardware accel detects VAAPI on `/dev/dri/renderD128`; or play+transcode and watch jellyfin logs for VAAPI / `radeonsi`.

### R4 — bring qbit up (fresh key already in the Talos secret)
- `sed -i '' 's/^  replicas: 0.*/  replicas: 1/' workloads/qbittorrent/deployment.yaml` → commit → push → hard-refresh `qbittorrent` Argo app.
- Verify VPN: gluetun `tun0 rx_bytes > 0`, `/v1/publicip/ip` populated, `/tmp/gluetun/forwarded_port` set, qbit `connection_status: connected`, **0 restarts in 60s**.
- If it flaps again on a STABLE network → tune gluetun (raise `HEALTH_VPN_DURATION_INITIAL`, or try a different P2P server) — but with the fresh key + stable net it should hold.
- Test sonarr/radarr download client: `POST /api/v3/downloadclient/test` → 200.

### R5 — k0s qbit secret (once k0s/aether is back)
- Patch k0s `protonvpn-secret` (default ns) with the same fresh key so qbit is switch-ready on both clusters:
  extract PrivateKey/Address from `wg-US-MI-1.conf` → `kubectl --context homelab-cluster -n default patch secret protonvpn-secret --type merge -p '{"stringData":{"WIREGUARD_PRIVATE_KEY":"...","WIREGUARD_ADDRESSES":"..."}}'`.

### R6 — cleanup (optional)
- Delete NFS staging (~750 MB): a pod mounting `192.168.1.210:/volume1/appconfig` → `rm -rf /nfs/.staging`.
- Drop the demo `switched-from-talos` prowlarr tag + any orphan NAS test subdirs.

---

## Durable fix — vendor-reset (so GPU moves never hang the host again)
The whole aether-hang happened because Renoir iGPUs don't support PCI function-level reset; moving the
GPU between VMs (or hard-stopping the holder) wedges it, and a wedged GPU can hang the host at POST.
Install `vendor-reset` on the aether Proxmox host (root): DKMS module + set the GPU's
`reset_method=device_specific` + reboot. After that the GPU resets cleanly on every VM move — which is
also what makes the eventual **"switch button"** (move GPU k0s↔talos via the token + the `vega-igpu`
mapping) safe to automate.

## Gotchas learned this session (candidates for talos-gotchas.md)
1. **Cilium L2 SPOF:** never pin `CiliumL2AnnouncementPolicy.nodeSelector` to one hostname — when that
   node dies, the LB IP goes dark with no failover. Use `kubernetes.io/os: linux` for leader-election failover.
2. **AMD Renoir/Vega passthrough reset bug:** hard-stopping the VM holding the iGPU wedges it; the next
   VM fails to start ("failed to reset PCI device"); host reboot resets it but a wedged GPU can hang POST.
   Fix = vendor-reset. Always graceful-shutdown the GPU VM, never hard-stop.
3. **Proxmox passthrough w/ a non-root API token:** raw `hostpci0=0000:..` needs root; use a PCI
   **resource mapping** (token needs Mapping.Use) — and the mapping MUST include `iommugroup` +
   `subsystem-id` or VM start fails with "missing expected property 'iommugroup'".
4. **Proxmox config API:** `PUT /qemu/{id}/config` is async (returns a UPID) — wait for the task / verify.
5. **ProtonVPN+gluetun:** rapid reconnect storms get the WG key rate-limited (rx=0, healthcheck i/o
   timeouts, ~6s restart loop). A fresh key clears it; cross-test on BOTH clusters to prove it's the
   key/server not the cluster. Extract the key with `cut -d=` (base64 ends in `=`).
