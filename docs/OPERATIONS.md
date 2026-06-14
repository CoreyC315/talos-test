# OPERATIONS — the 30-second orientation (read this first when something's wrong)

Dense operator's map. Not narrative — for fast triage. Deep dives are linked at the bottom.

## What this is, right now
A 6-node Talos/Kubernetes cluster on 3 Proxmox hosts, **one control plane + one worker per host**,
reconciled by Argo CD from this repo. Rebuilt from scratch via `terraform apply` (fresh PKI/etcd).
Healthy state = **32/32 Argo apps Synced+Healthy**, all 6 nodes Ready, the demo app serving HTTP 201.

```bash
cd ~/dev/talos-test && export KUBECONFIG=$PWD/terraform/.kubeconfig
kubectl get nodes                                   # 6 Ready
kubectl -n argocd get applications | grep -v "Synced.*Healthy"   # only header = all healthy
curl -sk https://app.192.168.1.27.nip.io/api/stats  # app alive
```

## Where everything is (load-bearing locations)
| Thing | Location |
|---|---|
| kubeconfig | `terraform/.kubeconfig` **and** `talos/clusterconfig/kubeconfig` (same) |
| talosconfig | `talos/clusterconfig/talosconfig` (talosctl needs `-e <node-ip>` if endpoints unset) |
| **Vault unseal key + root token** | `~/kubeshowcase-capsules/vault-init.json` (also inside each NAS capsule's `secrets.tar.enc`) — **the cluster has no copy; lose this = lose Vault** |
| SOPS age private key | `~/.config/sops/age/keys.txt` (decrypts `*.sops.yaml`; never in Git) |
| NAS time-capsules | `NAS(192.168.1.210):/volume1/backups/kubeshowcase/*.tar.gz` + local `~/kubeshowcase-capsules/` |
| Longhorn off-cluster backups | `NAS:/volume1/backups/longhorn` (NFSv3) |
| In-cluster app registry | `192.168.1.23:5000` (plain HTTP, hostPort on worker-1) |
| Proxmox API | `https://192.168.1.100:8006` (token in `terraform/terraform.tfvars`, gitignored) |
| Terraform state | `terraform/terraform.tfstate` (gitignored; has PKI) |

## The map (topology)
| Proxmox host | RAM | Control plane | Worker | Notes |
|---|---|---|---|---|
| **raiden** | 16 GB | cp-1 `.20` (6G) | worker-3 `.25` (6G) | smallest host; keep lean |
| **aether** | ~29 GB | cp-2 `.21` (8G) | worker-1 `.23` (8G→7G) | **worker-1 = registry + Gateway L2 announcer** (the reliable node) |
| **nahida** | 33 GB | cp-3 `.22` (8G) | worker-2 `.24` (10G) | roomiest; *was* the I/O bottleneck pre-rebalance |
- VIP (kube-API) `192.168.1.19:6443`. Gateway VIP `192.168.1.27` → `*.192.168.1.27.nip.io`.
- Co-tenant k0s/k3s/PBS VMs (`303 nahida-worker`, `211 raiden-worker`, `304 PBS`) are **currently
  powered off** to free the hosts; `112 k0s-worker-aether-0` + `201 k3s-master-1` left running.
  See [[proxmox-host-topology]].

## UIs (all behind the Gateway, self-signed TLS — `-k`/accept cert)
`https://argocd | grafana | hubble | longhorn | minio | vault | goldilocks | app .192.168.1.27.nip.io`
(Argo CD admin password: `kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d`)

## If X breaks → likely cause → do this
| Symptom | Most likely cause | First move |
|---|---|---|
| App pods `ErrImagePull` `192.168.1.23:5000/...` "not found" | **Spegel hijacked the in-cluster registry** (its `mirroredRegistries`/`prependExisting` reverted) | check `apps/platform/spegel.yaml` still lists the registry + `prependExisting: true`; restart spegel ds; gotcha re: registry below |
| `external-secrets`/`eso-config` Degraded after any restart | **Vault re-sealed** (no auto-unseal) | `UNSEAL=$(jq -r '.unseal_keys_b64[0]' ~/kubeshowcase-capsules/vault-init.json); kubectl -n vault exec vault-0 -- vault operator unseal "$UNSEAL"` |
| Lots of cross-node failures (registry pulls, replication, probes) all at once | **MTU** (VXLAN needs 1450) | `kubectl -n kube-system get cm cilium-config -o jsonpath='{.data.mtu}'` must be `1450`; gotcha #12 |
| Gateway VIP `.27` stops answering (ARP) | Cilium L2 announcer wedged | gotcha #13 — restart announcer's cilium agent + delete the L2 lease |
| A whole tier never deploys; root "waiting for healthy state of X" | sync-wave gated on an unhealthy app (e.g. node-exporter PSA, sealed Vault) | find the gating app; fix it; the wave proceeds |
| `node-exporter` 0/N, "violates PodSecurity baseline" | ns missing privileged label | `monitoring` (and any hostPath ns) needs `pod-security.kubernetes.io/enforce=privileged` |
| Control plane unreachable / `talosctl etcd` hangs, hosts at high **iowait** | etcd page-cache thrash (undersized CP RAM) | gotcha #11 — quorum-preserving rolling RAM bump; resilience Incident 1 |
| Node `NotReady`, pods `Terminating` zombies, host load spiking | I/O-wedged node (usually nahida under co-tenant load) | **do NOT mass-delete pods** (makes it worse — gotcha #14); stop, let it quiesce, force-clear zombies |
| `terraform apply` fails on a fresh build | one of the 7 known gaps (all fixed) — but if seen: | resilience report → "clean-room rebuild" table; each has a committed fix |
| CNPG Postgres `1/2`, replica "Refusing to restore future timeline" | replica diverged after a failover | delete the bad instance's pod + PVC → CNPG re-clones via pg_basebackup |
| Longhorn volume `degraded` after a node drain | normal — `replica-replenishment-wait-interval` (~10 min) before rebuild | wait; volume is still serving on its other replica |

## Things that are NORMAL (don't "fix" these)
- **`ks-worker` Deployment at `0/0`** — KEDA scale-to-zero; it scales up only when the Redis queue has jobs.
- **Longhorn 1–2 `degraded` volumes shortly after a drain/reboot** — rebuilding on the timer; self-heals.
- **Argo `root` app `OutOfSync`** sometimes while children reconcile — fine if Healthy.
- **Trivy `scan-vulnerabilityreport` pods in `Error`** occasionally — individual scan retries; check `kubectl get vulnerabilityreports -A` is growing (was ~93).
- **Kyverno policies are `Audit`** (advisory), webhook `failurePolicy: Ignore` — by design, never wedges admission.

## Load-bearing facts that WILL bite if forgotten
- **Spegel must explicitly mirror the in-cluster registry** as `http://192.168.1.23:5000` with
  `prependExisting: true`, else its catch-all 404s app pulls (resilience report gap #6).
- **Vault re-seals on every restart** — manual unseal required (key location above). By design.
- **Longhorn → Synology needs `?nfsOptions=nfsvers=3,nolock,soft,timeo=300,retry=2`** (DSM is NFSv3-only).
- **One CP + one worker per host** is deliberate (no host failure takes 2 etcd members or 2 replicas).
- **Talos is API-only** — no SSH. Debug with `talosctl` (services/dmesg/logs) + `kubectl`, not ssh.
- The fresh-build fixes live in `terraform/` (IP discovery, HostnameConfig, overwrite_unmanaged) and
  `bootstrap/00-gateway-api-prep.sh` (API wait + TLSRoute v1alpha2) — don't regress them.

## Routine ops
```bash
# health
kubectl get nodes; kubectl -n argocd get applications | grep -v "Synced.*Healthy"
# take an off-site time-capsule (repo+etcd+secrets → NAS, uploader pinned to worker-1)
./load-and-chaos/backup-to-nas.sh
# rebuild from nothing  /  adopt existing  /  restore data
#   → docs/REBUILD.md   (terraform apply → Argo → ./bootstrap/03-finish.sh)
# after a node reboot: check Vault sealed (unseal), Longhorn replicas rebuilding (wait)
```

## Deep-dive index
- [REBUILD.md](REBUILD.md) — rebuild + adopt + data-restore runbook (the recovery bible)
- [talos-gotchas.md](talos-gotchas.md) — 14 real failure→fix writeups (referenced by # above)
- [resilience-report.md](resilience-report.md) — 5 incidents + the clean-room rebuild (the 7 gaps)
- [feature-matrix.md](feature-matrix.md) — every feature + how to observe it
- [learn/](learn/README.md) — the full curriculum (what each tool *is*)
- `versions.lock.md` — pinned versions
