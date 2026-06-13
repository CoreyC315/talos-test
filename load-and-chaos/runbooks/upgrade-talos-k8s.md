# Upgrade exhibit — zero-downtime Talos OS + Kubernetes bumps

Talos's headline feature: atomic, API-driven, one-node-at-a-time upgrades with automatic
cordon/drain, no SSH, no package manager.

## etcd snapshot first (always, before any CP change)
```bash
export TALOSCONFIG=talos/clusterconfig/talosconfig
talosctl -n 192.168.1.20 etcd snapshot etcd-$(date +%Y%m%d).snap
ls -lh etcd-*.snap   # off-box this to Synology/MinIO for real DR
```

## A. Talos OS upgrade (image bump, one node at a time, workers first then CP)
The installer image is the Image Factory schematic URL. To bump the Talos version, change the
tag (e.g. v1.13.4 -> v1.13.5) — same schematic ID keeps the extensions.
```bash
IMG=factory.talos.dev/installer/7d1fa2e0d2d77244e6ab651eb49a9772e2c905c87ae4f1bd5833df1d7832a092:v1.13.5
for n in 192.168.1.25 192.168.1.24 192.168.1.23 192.168.1.22 192.168.1.21 192.168.1.20; do
  echo "=== upgrading $n"
  talosctl -n $n upgrade --image $IMG --wait --timeout 15m
  talosctl -n $n health --server=false
  kubectl get nodes      # confirm node Ready before moving on
done
```
Talos cordons+drains each node, reboots into the new image, uncordons. PDBs keep the app up.
Watch the app stay served:
```bash
while true; do date -u +%T; curl -sk -m3 -o /dev/null -w "%{http_code}\n" https://app.192.168.1.27.nip.io/api/items; sleep 2; done
```

## B. Kubernetes minor bump (1.35 -> 1.36)
Driven entirely by talosctl — it sequences apiserver/controller-manager/scheduler/kubelet.
```bash
talosctl -n 192.168.1.20 upgrade-k8s --to 1.36.2
kubectl get nodes      # VERSION column climbs to v1.36.2 node by node
kubectl version
```

## Record for the Resilience Report
- Before/after: `kubectl get nodes` VERSION + `talosctl version`
- App availability during each phase (curl loop: count of non-200s)
- Total wall-clock per node; confirm workloads never fully went down
