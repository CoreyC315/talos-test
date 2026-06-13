# Feature Matrix — every demonstrated feature, where it lives, how to see it work

## Talos / OS layer
| Feature | File / config | Observe it |
|---|---|---|
| Image Factory schematic (extensions: iscsi-tools, util-linux-tools, qemu-guest-agent, intel-ucode) | `talos/schematic.yaml` | `talosctl -n 192.168.1.23 get extensions` |
| API-only node ops (no SSH anywhere) | whole repo | `talosctl -n 192.168.1.20 dashboard` |
| HA control plane VIP | `talos/patches/nodes/cp-*.yaml` (`vip: 192.168.1.19`) | power off one CP → `kubectl --server https://192.168.1.19:6443 get nodes` keeps working |
| KubePrism HA apiserver endpoint | `talos/patches/common.yaml` (`kubePrism: port 7445`) | `platform/cilium/values.yaml` points Cilium at `localhost:7445` |
| LUKS2 disk encryption (STATE+EPHEMERAL) | `talos/patches/common.yaml` (`systemDiskEncryption`) | `talosctl -n <node> get volumestatus` shows `encrypted` |
| CNI=none + kube-proxy disabled | `talos/patches/cluster.yaml` | `kubectl -n kube-system get ds kube-proxy` → NotFound |
| Node zone labels from Proxmox host | `talos/patches/nodes/*.yaml` (`topology.kubernetes.io/zone`) | `kubectl get nodes -L topology.kubernetes.io/zone` |
| Registry mirrors (Spegel + fallback + in-cluster) | `talos/patches/common.yaml` (`registries.mirrors`) | `talosctl -n <node> read /etc/cri/conf.d/hosts/docker.io/hosts.toml` |
| SOPS-encrypted Talos secrets bundle | `talos/secrets.sops.yaml` | `sops -d talos/secrets.sops.yaml` (needs age key) |
| Zero-downtime OS upgrade | runbook `load-and-chaos/runbooks/` | `talosctl upgrade` one node at a time (Resilience Report) |
| etcd snapshot DR | runbook | `talosctl -n 192.168.1.20 etcd snapshot db.snap` |

## Networking (Cilium)
| Feature | File | Observe |
|---|---|---|
| eBPF kube-proxy replacement | `platform/cilium/values.yaml` | `cilium status`; `kubectl -n kube-system exec ds/cilium -- cilium-dbg status --verbose \| grep KubeProxy` |
| LB-IPAM + L2 announcements (pool .26–.30) | `platform/cilium/manifests/lb-ipam.yaml` | `kubectl get svc -A \| grep LoadBalancer` — external IPs from pool |
| Gateway API north-south + TLS | `platform/gateway/gateway.yaml` | `curl -k https://app.192.168.1.27.nip.io` |
| Hubble flow observability | values: `hubble.ui.enabled` | https://hubble.192.168.1.27.nip.io — watch verdicts live |
| Default-deny + L3/L4 + **L7 HTTP** policy | `workloads/kubeshowcase/netpol.yaml` | `kubectl exec` a frontend pod → `curl api:8080/api/items` allowed, `DELETE /api/items` rejected at L7; red drops in Hubble |
| DNS-aware egress policy | same file (`allow-dns` with `rules.dns`) | Hubble shows DNS queries with FQDN |

## GitOps (Argo CD)
| Feature | File | Observe |
|---|---|---|
| App-of-apps root | `bootstrap/root-app.yaml` → `apps/**` | Argo CD UI tree view |
| Sync waves (CRDs→controllers→instances) | `argocd.argoproj.io/sync-wave` in every `apps/*.yaml` | app list ordered 0→7 |
| Automated sync + prune + self-heal | every Application `syncPolicy` | `kubectl delete deploy/ks-frontend -n kubeshowcase` → recreated in seconds |
| SOPS/age secrets decrypted on sync (KSOPS) | `bootstrap/argocd/values.yaml` repoServer + `*/ksops-generator.yaml` | secrets exist in-cluster; Git holds only `ENC[...]` |
| Multi-source apps (chart + values + manifests from git) | e.g. `apps/platform/longhorn.yaml` | — |
| Self-managing Argo CD | `apps/platform/argocd.yaml` | edit values in Git → Argo CD updates itself |

## Storage / Data
| Feature | File | Observe |
|---|---|---|
| Longhorn default SC, 1 replica | `apps/platform/longhorn.yaml` | https://longhorn.192.168.1.27.nip.io |
| Longhorn S3 backups + recurring jobs | `platform/longhorn/manifests/recurring-backup.yaml` | Longhorn UI → Backup tab; MinIO bucket `longhorn-backups` |
| CNPG operator-managed HA Postgres | `workloads/kubeshowcase/postgres.yaml` | `kubectl -n kubeshowcase get cluster ks-db` → 2 instances, streaming replication |
| CNPG WAL archiving + scheduled base backups → S3 | same (barmanObjectStore + ScheduledBackup) | MinIO bucket `cnpg-backups` |
| MinIO S3 + bucket bootstrap Job | `apps/platform/minio.yaml` (`buckets:`) | https://minio.192.168.1.27.nip.io |

## Observability
| Feature | File | Observe |
|---|---|---|
| Metrics (kube-prometheus-stack, all ServiceMonitors) | `apps/observability/kube-prometheus-stack.yaml` | Grafana → Explore → Prometheus |
| Logs (Loki on S3, Alloy collector) | `apps/observability/loki.yaml`, `apps/observability/alloy.yaml` | Grafana → Explore → Loki `{namespace="kubeshowcase"}` |
| Traces (Tempo on S3, OTel end-to-end) | `apps/observability/tempo.yaml` + `app-src/api/tracing.go` | Grafana → Explore → Tempo; frontend→API→DB spans |
| Logs↔traces correlation (trace_id derived field) | kps values: Loki datasource derivedFields | click trace_id in a log line → Tempo trace |
| Exemplars (metrics→traces) | API histogram exemplars + `exemplar-storage` | Grafana panel → exemplar dots |
| Dashboards as code (4 ConfigMaps) | `observability/dashboards/` | Grafana → Dashboards |
| Meaningful alerts + live receiver | `observability/manifests/prometheusrules.yaml` | https://ntfy.sh/kubeshowcase-corey-alerts |
| Custom-metric pipeline (prometheus-adapter) | `apps/observability/prometheus-adapter.yaml` | `kubectl get --raw /apis/custom.metrics.k8s.io/v1beta1 \| jq` |

## Security / Governance
| Feature | File | Observe |
|---|---|---|
| PSS restricted on app ns / privileged documented | `workloads/kubeshowcase/namespace.yaml`, `security/pss/namespaces.md` | `kubectl run --image=nginx root-test -n kubeshowcase` → denied |
| Kyverno policy-as-code (5 policies, audit) | `security/kyverno/policies/` | `kubectl get policyreports -A` |
| Trivy Operator vuln/misconfig scanning | `apps/security/trivy-operator.yaml` | `kubectl get vulnerabilityreports -A` |
| Falco runtime detection + Alertmanager | `apps/security/falco.yaml` | `kubectl exec` into a pod → Falco "shell in container" event |
| Vault + External Secrets (runtime secrets) | `security/eso/vault-store.yaml`, `workloads/kubeshowcase/external-secret.yaml` | `kubectl -n kubeshowcase get secret ks-vault-secret` |
| SOPS-in-Git vs ESO contrast | `workloads/kubeshowcase/sops-demo.sops.yaml` + comment in `external-secret.yaml` | both end up as env vars in `/api/stats` |
| kube-bench CIS scan | `security/kube-bench/job.yaml` | `kubectl -n kube-bench logs job/kube-bench` |
| Least-privilege RBAC | `workloads/kubeshowcase/rbac.yaml` | `kubectl auth can-i --as=system:serviceaccount:kubeshowcase:ks-api delete pods -n kubeshowcase` → no |

## Workload primitives (namespace kubeshowcase)
| Feature | File | Observe |
|---|---|---|
| HPA: CPU + custom Prometheus metric | `workloads/kubeshowcase/autoscaling.yaml` | k6 run → `kubectl get hpa -w` |
| KEDA: Redis list, scale-to-zero | same | queue 100 jobs → worker 0→N→0 |
| VPA `InPlaceOrRecreate` + Goldilocks | same + goldilocks app | `kubectl get vpa -n kubeshowcase`; https://goldilocks.192.168.1.27.nip.io |
| Argo Rollouts canary + Prometheus AnalysisTemplate + auto-rollback | `workloads/kubeshowcase/api.yaml` | bump image tag → `kubectl argo rollouts get rollout ks-api -w` |
| PodDisruptionBudgets | `pdb.yaml` | node drain drill (Resilience Report) |
| Topology spread (hostname + zone) | `api.yaml`, `frontend.yaml` | `kubectl get pods -o wide -n kubeshowcase` |
| Init container migration gate | `api.yaml` (initContainer `migrate`) | pod events: migrate completes before app starts |
| Startup+readiness+liveness probes everywhere | all workload files | `kubectl describe pod` |
| ConfigMap + 2 secret mechanisms + Reloader | `configmap.yaml` + reloader annotations | edit ks-config → pods roll automatically |
| ResourceQuota + LimitRange | `quota.yaml` | `kubectl describe quota -n kubeshowcase` |
| CronJob (pg_dump → MinIO) | `cronjob.yaml` | `kubectl create job --from=cronjob/ks-pgdump manual -n kubeshowcase`; bucket `pg-dumps` |
| Gateway HTTPRoute path-split (SPA + API one hostname) | `httproute.yaml` | https://app.192.168.1.27.nip.io |
