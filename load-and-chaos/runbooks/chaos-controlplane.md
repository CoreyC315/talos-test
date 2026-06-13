# Chaos drill — control-plane node failure (HA proof)

**Hypothesis:** powering off ONE control-plane node keeps the cluster fully usable — the Talos
VIP `192.168.1.19` fails over to a surviving CP, and etcd keeps quorum at 2/3.

> ⚠️ NEVER power off two CP nodes — 1/3 loses etcd quorum and the API goes read-only/down.

## Pre-checks
```bash
export TALOSCONFIG=talos/clusterconfig/talosconfig KUBECONFIG=talos/clusterconfig/kubeconfig
talosctl -n 192.168.1.20 etcd members      # expect 3 members, all started
talosctl -n 192.168.1.19 version           # VIP answers (currently routed to some CP)
kubectl get nodes                          # all Ready
# which CP currently holds the VIP?
for n in 20 21 22; do echo -n ".$n: "; talosctl -n 192.168.1.$n get addresses 2>/dev/null | grep -c 192.168.1.19; done
```

## Inject — power off the CP that holds the VIP (worst case)
```bash
source .env
# e.g. cp-2 = vmid 221 on aether
curl -sk -X POST -H "Authorization: PVEAPIToken=$PROXMOX_TOKEN" \
  "$PROXMOX_URL/nodes/aether/qemu/221/status/stop" -d ''
date -u +%T   # T0
```

## Observe
```bash
# VIP keeps answering (fails over to another CP):
while true; do date -u +%T; talosctl -n 192.168.1.19 version --short 2>&1 | head -1; sleep 2; done
# API keeps serving via VIP:
while true; do kubectl get --raw /healthz 2>&1; echo " @$(date -u +%T)"; sleep 2; done
# etcd quorum (query a SURVIVING CP, not the dead one):
talosctl -n 192.168.1.20 etcd members      # 1 member unhealthy, quorum still 2/3
```
**Expected:** VIP unreachable for ~5–15s, then a surviving CP claims it (L2/ARP) and answers.
`kubectl` recovers in the same window. etcd reports the dead member down but stays writable.
Workloads in kubeshowcase are unaffected throughout (they don't touch the CP directly).

## Recover
```bash
curl -sk -X POST -H "Authorization: PVEAPIToken=$PROXMOX_TOKEN" \
  "$PROXMOX_URL/nodes/aether/qemu/221/status/start" -d ''
talosctl -n 192.168.1.21 health --server=false
talosctl -n 192.168.1.20 etcd members      # all 3 healthy again
```

## Record
- T0 (power off), T1 (VIP answers from new CP), T2 (kubectl healthy)
- VIP failover gap (seconds)
- Confirm etcd never lost quorum (writes succeeded throughout)
