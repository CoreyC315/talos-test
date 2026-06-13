# Chaos drill — worker node failure (data plane)

**Hypothesis:** killing a worker node does not take the app down. PDBs hold a survivor,
topology-spread + the scheduler reschedule the evicted pods onto the other two workers, and
Longhorn rebuilds the lost replica from its surviving copy.

## Pre-checks
```bash
export KUBECONFIG=talos/clusterconfig/kubeconfig TALOSCONFIG=talos/clusterconfig/talosconfig
kubectl get pods -n kubeshowcase -o wide          # note which worker each pod sits on
kubectl get pdb -n kubeshowcase                    # ALLOWED DISRUPTIONS >= 1 on api/frontend
kubectl -n longhorn-system get volumes.longhorn.io # all "Healthy", robustness "healthy"
curl -sk https://app.192.168.1.27.nip.io/api/stats # baseline served pod + item count
```

## Inject (graceful — cordon + drain)
```bash
# Pick the worker hosting the most app pods, e.g. worker-2 (192.168.1.24)
kubectl cordon worker-2
kubectl drain worker-2 --ignore-daemonsets --delete-emptydir-data --force --grace-period=30
date -u +%T   # T0
```

## Or inject (hard — Proxmox power-off, simulates real failure)
```bash
source .env
curl -sk -X POST -H "Authorization: PVEAPIToken=$PROXMOX_TOKEN" \
  "$PROXMOX_URL/nodes/nahida/qemu/224/status/stop" -d ''
```

## Observe (keep a loop running through the whole event)
```bash
# App stays up:
while true; do date -u +%T; curl -sk -m3 -o /dev/null -w "%{http_code}\n" \
  https://app.192.168.1.27.nip.io/api/items; sleep 2; done
# Pods reschedule:
kubectl get pods -n kubeshowcase -o wide -w
# Longhorn rebuilds:
kubectl -n longhorn-system get volumes.longhorn.io -w
```
**Expected:** HTTP 200 throughout (maybe 1–2 blips during canary pod move). Node → NotReady
in ~40s; evicted pods Pending → Running on worker-1/worker-3 within ~30–60s (topology spread
keeps them split). Longhorn volume robustness → "degraded" then "healthy" after rebuild.

## Recover
```bash
# graceful path:
kubectl uncordon worker-2
# hard path: power the VM back on
curl -sk -X POST -H "Authorization: PVEAPIToken=$PROXMOX_TOKEN" \
  "$PROXMOX_URL/nodes/nahida/qemu/224/status/start" -d ''
# Talos rejoins automatically; verify:
talosctl -n 192.168.1.24 health --server=false
kubectl get nodes
```

## Record for the Resilience Report
- T0 (drain/stop), T1 (node NotReady), T2 (all pods Running again), T3 (Longhorn healthy)
- Max consecutive non-200s on the curl loop (recovery gap, if any)
- Longhorn rebuild duration
