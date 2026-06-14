# KubeShowcase — a production-grade Talos Linux platform on a shared homelab

A complete, GitOps-driven Kubernetes platform on **Talos Linux v1.13.4** (API-only, immutable,
SSH-less) across 6 VMs on a 3-node Proxmox cluster, reconciled end-to-end by **Argo CD** from
this repo, carrying a full LGTM observability stack, a security/governance tier, and a
multi-tier demo app exercising every autoscaler and workload primitive Kubernetes has.

> **Hardware honesty:** the original 48–72 GiB plan did not survive contact with reality
> (~29 GiB free across the Proxmox hosts, which also run a busy co-tenant k0s cluster + HA + PBS).
> It started at ~22.5 GiB of new VMs and **grew to 40 GiB / 30 vCPU** after real incidents proved
> the control plane needed etcd headroom (see the *Resilience Report*). Single-replica
> observability, Longhorn `numberOfReplicas=1`, documented Stretch-tier triage. See *Resource budget*.

## Architecture

```mermaid
flowchart TB
  subgraph proxmox["Proxmox (raiden 16G · aether 27G · nahida 31G)"]
    subgraph talos["Talos v1.13.4 — K8s v1.35.6, KubePrism :7445, LUKS2, no SSH"]
      cp1["cp-1 .20 (raiden)"]; cp2["cp-2 .21 (aether)"]; cp3["cp-3 .22 (nahida)"]
      w1["worker-1 .23 (aether)"]; w2["worker-2 .24 (nahida)"]; w3["worker-3 .25 (nahida)"]
    end
  end
  vip["CP VIP 192.168.1.19"] --- cp1 & cp2 & cp3
  subgraph net["Cilium 1.19 (eBPF, kube-proxy-free)"]
    lbipam["LB-IPAM + L2 .26–.30"]
    gw["Gateway API: shared Gateway @ .27<br/>*.192.168.1.27.nip.io (homelab CA TLS)"]
    hubble["Hubble + UI (L7 flow visibility)"]
  end
  subgraph core["Core"]
    argocd["Argo CD (app-of-apps, KSOPS/SOPS)"]
    lh["Longhorn (default SC, 1 replica)"]
    minio["MinIO S3 (loki/tempo/velero/cnpg/longhorn buckets)"]
    cm["cert-manager: root→intermediate→leaf CA"]
    spegel["Spegel p2p image mirror :29999"]
    reg["registry :5000 @ .23 (app images)"]
  end
  subgraph obs["Observe (ns monitoring)"]
    prom["kube-prometheus-stack"]; loki["Loki (S3)"]; tempo["Tempo (S3)"]
    alloy["Alloy: logs + OTLP traces"]; graf["Grafana (dashboards as code)"]
  end
  subgraph sec["Secure"]
    kyv["Kyverno policies"]; trivy["Trivy Operator"]; falco["Falco eBPF"]
    vault["Vault + External Secrets"]; bench["kube-bench"]
  end
  subgraph app["kubeshowcase (PSS restricted, default-deny L7 netpol)"]
    fe["React SPA (VPA in-place)"] --> api["Go API — Rollout canary + HPA (CPU+RPS)"]
    api --> pg["CNPG Postgres ×2 + WAL→S3"]
    api --> redis["Redis queue"]
    redis --> wk["Go worker — KEDA scale-to-zero"]
    api -. OTLP .-> alloy
  end
  gw --> fe & api
```

## Service access

DNS-free by design: `*.192.168.1.27.nip.io` resolves to the shared Gateway (192.168.1.27).
All HTTPS, certs issued by the **KubeShowcase intermediate CA**.

| Service | URL | Auth |
|---|---|---|
| KubeShowcase app | https://app.192.168.1.27.nip.io | none |
| Argo CD | https://argocd.192.168.1.27.nip.io | `admin` / `kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' \| base64 -d` |
| Grafana | https://grafana.192.168.1.27.nip.io | `admin` / SOPS: `sops -d observability/manifests/grafana-admin.sops.yaml` |
| Hubble UI | https://hubble.192.168.1.27.nip.io | none |
| Longhorn | https://longhorn.192.168.1.27.nip.io | none |
| MinIO console | https://minio.192.168.1.27.nip.io | SOPS: `sops -d platform/minio/manifests/minio-root.sops.yaml` |
| Vault | https://vault.192.168.1.27.nip.io | root token from `security/vault/seed-vault.sh` init output |
| Goldilocks | https://goldilocks.192.168.1.27.nip.io | none |

**Trust the CA once:** `kubectl -n cert-manager get secret homelab-root-ca -o jsonpath='{.data.tls\.crt}' | base64 -d > root-ca.crt`
then add to your trust store (macOS: `sudo security add-trusted-cert -d -k /Library/Keychains/System.keychain root-ca.crt`).

## Repo layout / tiers

| Path | Tier | Contents |
|---|---|---|
| `talos/` | Core | factory schematic (ID committed), machine patches, SOPS-encrypted secrets bundle |
| `bootstrap/` | Core | `01-bootstrap-core.sh` (Gateway API CRDs + Cilium), `02-bootstrap-argocd.sh` (Argo CD + age key + root app) — the ONLY imperative steps |
| `platform/` | Core | cilium, gateway, cert-manager CA chain, longhorn, minio, spegel, metrics-server, registry, velero, argocd config |
| `observability/` | Observe | kube-prometheus-stack, loki, tempo, alloy, prometheus-adapter, dashboards (JSON as ConfigMaps), PrometheusRules |
| `security/` | Secure | kyverno policies, trivy, falco, vault (+seed script), ESO store, kube-bench, PSS rationale |
| `apps/` | — | Argo CD Application definitions only (root recurses this dir) |
| `workloads/kubeshowcase/` | App | every manifest of the demo app |
| `app-src/` | App | Go API, Go worker, React frontend, pgdump image |
| `load-and-chaos/` | Stretch | k6 profile + Job, build script, chaos/DR runbooks |

## Reproduce from scratch

> **The full runbook is [docs/REBUILD.md](docs/REBUILD.md)** — fresh rebuild, adopting the
> existing cluster, and restoring *data* "as it was from where it was" (Longhorn-from-NAS, etcd
> snapshot, time-capsule). The quick path is below.

### Fast path — Terraform (recommended): the whole thing in one `apply`
[`terraform/`](terraform/) rebuilds **everything up to the GitOps handoff** in a single command:
3 ISOs → 6 Proxmox VMs (final post-incident sizes) → Talos bootstrap → **Cilium** → **Argo CD + root
app-of-apps**. Argo CD then reconciles every tier from Git.
```bash
cd terraform && cp terraform.tfvars.example terraform.tfvars   # add Proxmox token
terraform init && terraform apply                              # ~one command; kubeconfig auto-written
export KUBECONFIG=$PWD/../talos/clusterconfig/kubeconfig
kubectl -n argocd get applications -w                          # watch the fleet converge
```
`terraform destroy && terraform apply` = clean rebuild. See [terraform/README.md](terraform/README.md)
for importing the existing cluster vs. a fresh build. The manual/imperative steps below are the same
operations Terraform automates (the `bootstrap/*.sh` scripts share the tricky Gateway-API prep with
Terraform so they can't drift) — kept for reference and to understand each layer.

### Manual path (what Terraform automates)
1. **Phase 0 — image:** schematic in `talos/schematic.yaml` (ID `7d1fa2e0…2a092`: iscsi-tools,
   util-linux-tools, qemu-guest-agent, intel-ucode). Download ISO to each Proxmox node's
   `local` storage via `download-url` API.
2. **VMs:** 6× q35/virtio VMs (IDs 220–225 ↔ IPs .20–.25), `cpu=host`, boot order disk→ISO.
   Sizing: **CPs 4c/8G/40G** (cp-1 capped at 6G — raiden is a 16G host shared with k0s);
   workers 6c/4–5G/70G. One CP per Proxmox host (quorum survives
   any single host failure).
3. **Talos:** `talosctl gen config kubeshowcase https://192.168.1.19:6443 --with-secrets <(sops -d talos/secrets.sops.yaml) --kubernetes-version 1.35.6 --config-patch @talos/patches/common.yaml --config-patch-control-plane @talos/patches/cluster.yaml`
   then per node `talosctl apply-config --insecure -n <dhcp-ip> -f <role>.yaml --config-patch @talos/patches/nodes/<node>.yaml`
   (map maintenance nodes to roles by MAC — `talosctl get hardwareaddresses --insecure`).
   `talosctl bootstrap -n 192.168.1.20` (retry until accepted) → `talosctl kubeconfig`.
4. **Core:** `./bootstrap/01-bootstrap-core.sh` (Gateway API CRDs incl. the TLSRoute/Cilium
   workaround, Cilium, LB-IPAM) → `./bootstrap/02-bootstrap-argocd.sh` (needs the age key at
   `~/.config/sops/age/keys.txt`). Argo CD then converges every tier from Git, in sync-wave order.
5. **Images:** `./load-and-chaos/build-and-push.sh 1.0.0` (local docker build → crane push to
   the in-cluster registry at .23).
6. **Vault (one-time):** `./security/vault/seed-vault.sh` — init/unseal, kv `kubeshowcase/api`,
   Kubernetes auth role for ESO.

Everything else — observability, security, the app — arrives via Argo CD with **no kubectl**.

## Resource budget (actuals)

Final VM allocation: **45 GiB / 28 vCPU** — grown from the planned 22.5 GiB through the
incident-driven RAM bumps (control plane needed real headroom for etcd; see Resilience Report
Incident 1) and the post-Incident-5 rebalance. One CP + one worker per Proxmox host so no single
host failure can take 2 etcd members or 2 Longhorn replicas.

| VM | Role | Host | vCPU | RAM | Notes |
|---|---|---|---|---|---|
| cp-1 | control plane | raiden | 4 | 6 GiB | shares raiden (16 GiB) with worker-3 |
| cp-2 | control plane | aether | 4 | 8 GiB | |
| cp-3 | control plane | nahida | 4 | 8 GiB | |
| worker-1 | worker | aether | 6 | 7 GiB | hosts registry + Gateway L2 announcer (the reliable node) |
| worker-2 | worker | nahida | 6 | 10 GiB | roomy host (33 GiB) gets the fattest worker |
| worker-3 | worker | raiden | 4 | 6 GiB | **moved off nahida** → exactly one CP + one worker per host |

> **Balanced topology (post-Incident-5):** every Proxmox host runs exactly one control plane +
> one worker, so no host carries two etcd members *or* two Longhorn replica targets. This replaced
> the original layout where `nahida` hosted 3 of 6 VMs and became the I/O bottleneck.

**Measured steady-state** (`kubectl top`, ~15 h soak):
- Control plane: cp-1 3.7 GiB (69%), cp-2 4.0 GiB (55%), cp-3 4.1 GiB (56%) — etcd + apiserver
  static pods dominate; the headroom over the old 2.5 GiB is what keeps etcd off the OOM/thrash cliff.
- Workers: worker-1 3.7 GiB (49%), worker-3 3.0 GiB (68%).
- Per-tier RAM: kube-system ≈ 8.6 GiB (Cilium ×6 + Envoy ×6 + etcd/apiserver static pods),
  monitoring ≈ 2.1 GiB (Prometheus+Loki+Tempo+Grafana+Alloy), Longhorn ≈ 0.8 GiB,
  Falco ≈ 0.47 GiB, the **whole KubeShowcase app ≈ 0.18 GiB**, Argo CD ≈ 0.13 GiB.

> The platform overhead (CNI, observability, storage, security) dwarfs the demo app — which is
> the honest reality of a "showpiece" cluster: you are paying for the *platform*, not the workload.

## Feature matrix

See [docs/feature-matrix.md](docs/feature-matrix.md) — one row per demonstrated feature with
file path + how to observe it.

## Learn this stack

New to half these tools? [**docs/learn/**](docs/learn/README.md) is a hands-on curriculum that
teaches every component **by poking this live cluster** — 8 weekend-sized modules (foundations →
networking → GitOps → storage → scaling → observability → security → release/ops), each with a lab
you run against your own cluster, interview-style questions, and CKA/CKAD/CKS cert mapping. Start
with the [decoder ring](docs/learn/README.md#the-decoder-ring--what-even-is-that-in-one-line-each).

## Reports

- [docs/REBUILD.md](docs/REBUILD.md) — authoritative rebuild + data-restore runbook
- [docs/talos-gotchas.md](docs/talos-gotchas.md) — every real failure we hit and the fix
- [docs/resilience-report.md](docs/resilience-report.md) — load, chaos, DR, upgrade timelines
- `versions.lock.md` — every pinned version

## Deviations from the original spec (documented trade-offs)

1. **RAM reality:** workers are 4–5 GiB, not 16 GiB; single-replica Prometheus/Loki/Tempo;
   Longhorn **1 replica** (2× write-amp on shared disks starved etcd — see gotcha #11);
   Pyroscope (Stretch) dropped — it does not fit honestly. **Control-plane RAM was raised
   2.5G→8G** after etcd page-cache thrash took the cluster down at ~hour 13 (gotcha #11): a
   CRD-heavy cluster's etcd needs real headroom even though CP nodes run ~zero workload pods.
2. **Cilium LB-IPAM** chosen over MetalLB (one fewer component, same L2 announcement job).
3. **ReplicaSet-based canary** (Argo Rollouts) instead of Gateway-API traffic splitting — the
   gatewayAPI plugin adds a controller; replica-weighting demonstrates analysis/rollback identically.
4. **App images in an in-cluster registry** (.28) — the available GitHub token lacks
   `write:packages` for ghcr.io. Swap `REGISTRY=ghcr.io/coreyc315 ./load-and-chaos/build-and-push.sh`
   once a proper PAT exists.
5. **ingress-nginx absent entirely** (retired upstream 2026) — Gateway API only.
6. **Renovate/cosign**: not deployed (RAM + scope honesty); Renovate config stub would be the
   next increment.
