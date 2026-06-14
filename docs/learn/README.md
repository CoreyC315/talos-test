# Learn This Stack — a hands-on Kubernetes curriculum built on *your* cluster

You built a production-grade Talos + Kubernetes platform. This curriculum teaches you what every
piece actually does — not from generic tutorials, but by **poking the live cluster you already
own**. That's the fastest way to learn infra: read the concept, then run a command and *watch it be
true*. Finish this and you can hold your own in a Platform Engineer / SRE / DevOps interview and
explain a real, opinionated production system end-to-end.

## How to use this

1. **One-time setup** — point your shell at the cluster (every lab assumes this):
   ```bash
   cd ~/dev/talos-test
   export KUBECONFIG=$PWD/terraform/.kubeconfig   # talosctl uses talos/clusterconfig/talosconfig
   kubectl get nodes          # should list cp-1..3, worker-1..3 = you're wired up
   ```
2. **Work a module per sitting.** Each is ~a focused weekend: read *The big picture* → read each
   tool → **do the Hands-on lab** (this is where it sticks) → quiz yourself with *Check yourself*.
3. **Keep the cluster running while you learn.** If it's powered off, bring it back with
   [REBUILD.md](../REBUILD.md). The whole point is that the thing in front of you is real.
4. **Don't memorize — explain.** After each module, try to say out loud "what problem does X solve,
   and how?" If you can teach it, you know it.

> Total: ~8 weekends to go deep, or ~2 weeks of evenings to get conversational. You do **not** need
> to finish before applying to jobs — even Modules 1–3 make you dangerous.

---

## The decoder ring — "what even is that?" in one line each

The fast cure for "there's a bunch I don't know what they do." Skim this first; it'll make the
module list stop looking like alphabet soup.

| Thing | In one line | Module |
|---|---|---|
| **Proxmox** | The hypervisor — software that carves physical servers into virtual machines. | 1 |
| **Terraform** | "Infrastructure as code" — declare your VMs/cluster in files; `apply` makes reality match. | 1 |
| **Talos Linux** | A stripped-down OS that exists *only* to run Kubernetes — no SSH, configured by API. | 1 |
| **etcd** | The cluster's database — every object lives here; loses quorum, cluster freezes. | 1 |
| **kube-apiserver** | The front door — everything (`kubectl`, controllers) talks to the cluster through it. | 1 |
| **kubelet** | The agent on each node that actually starts/stops your containers. | 1 |
| **CNI / Cilium** | The plugin that gives pods IPs and routes their traffic; Cilium does it with eBPF. | 2 |
| **eBPF** | Run sandboxed programs *inside the Linux kernel* — how Cilium/Falco work without slow sidecars. | 2,7 |
| **Hubble** | Cilium's flow viewer — see every pod-to-pod connection live. | 2 |
| **Service** | A stable virtual IP/DNS name in front of a set of pods (which come and go). | 2 |
| **Gateway API / Ingress** | How outside traffic reaches your apps (Gateway API is the modern Ingress). | 2 |
| **CoreDNS** | In-cluster DNS — turns `my-svc.my-ns.svc` into an IP. | 2 |
| **GitOps** | Git is the single source of truth; a controller makes the cluster match the repo, always. | 3 |
| **Argo CD** | The GitOps engine here — watches this repo and reconciles the cluster to it. | 3 |
| **Helm** | A package manager for Kubernetes — installs apps from templated "charts." | 3 |
| **Kustomize** | Patch/overlay raw YAML without templating. | 3 |
| **SOPS / age / KSOPS** | Encrypt secrets so they can live *in Git* safely; decrypted only in-cluster. | 3 |
| **PV / PVC / CSI** | How pods get disks: a claim (PVC) binds to a volume (PV) via a storage driver (CSI). | 4 |
| **Longhorn** | Distributed block storage — replicates each volume across nodes so a node loss ≠ data loss. | 4 |
| **StatefulSet** | Like a Deployment but for pods with stable identity + their own disks (databases). | 4 |
| **CloudNativePG** | A Postgres operator — runs HA Postgres with automatic failover + backups. | 4 |
| **MinIO** | S3-compatible object storage you run yourself. | 4 |
| **Redis** | In-memory store — used here as a cache + work queue. | 4 |
| **requests / limits** | How much CPU/RAM a pod reserves (requests) and is capped at (limits). | 5 |
| **HPA** | Horizontal Pod Autoscaler — adds/removes pod *replicas* based on load. | 5 |
| **VPA / Goldilocks** | Vertical autoscaler — right-sizes a pod's requests/limits; Goldilocks recommends. | 5 |
| **KEDA** | Event-driven autoscaling — scales on queue depth etc., including **down to zero**. | 5 |
| **metrics-server** | Supplies `kubectl top` + basic CPU/RAM for HPA. | 5 |
| **Prometheus** | The metrics database — scrapes numbers from everything; queried with PromQL. | 6 |
| **Grafana** | Dashboards — graphs your metrics/logs/traces. | 6 |
| **Loki** | Logs database (like Prometheus but for log lines). | 6 |
| **Tempo** | Distributed tracing store — follow one request across services. | 6 |
| **Alloy** | The agent that collects metrics/logs/traces and ships them. | 6 |
| **RBAC** | Role-Based Access Control — who can do what in the cluster. | 7 |
| **Pod Security Standards** | Built-in guardrails (privileged/baseline/restricted) on what pods may do. | 7 |
| **Kyverno** | Policy-as-code — *admission control* that can block/mutate non-compliant resources. | 7 |
| **Falco** | Runtime threat detection — watches syscalls (via eBPF) for suspicious behavior. | 7 |
| **Trivy** | Scans container images + configs for known vulnerabilities. | 7 |
| **kube-bench** | Checks the cluster against the CIS security benchmark. | 7 |
| **Vault** | Central secrets manager — stores/issues secrets with auth + audit. | 7 |
| **External Secrets** | Syncs secrets *from* Vault *into* native Kubernetes Secrets. | 7 |
| **Argo Rollouts** | Progressive delivery — canary/blue-green deploys with automated analysis. | 8 |
| **Spegel** | Peer-to-peer image cache — nodes share pulled images so you don't re-download. | 8 |
| **cert-manager** | Automates TLS certificates (issue + auto-renew). | 8 |
| **Reloader** | Restarts pods when their ConfigMap/Secret changes. | 8 |
| **Velero** | Backup/restore of Kubernetes objects + volumes to object storage. | 8 |

---

## The learning path

Do them in order — each builds on the last. (One wrinkle: Module 5's *custom-metrics* autoscaling
leans on Prometheus from Module 6, so if you want, read Module 6's Prometheus section first, or just
take the forward-reference on faith — the lab still works.)

| # | Module | You'll be able to… | Headline tools |
|---|---|---|---|
| 1 | [Foundations](01-foundations.md) | Explain everything between power-on and `kubectl get nodes` | Proxmox, Terraform, Talos, etcd/apiserver/scheduler/kubelet |
| 2 | [Networking](02-networking.md) | Trace a packet pod→pod and internet→app, and debug each hop | Cilium/eBPF, Hubble, Services, Gateway API, CoreDNS |
| 3 | [GitOps & Config](03-gitops.md) | Read any Argo app, explain its sync/health, ship a change via Git | Argo CD, Helm, Kustomize, SOPS/age |
| 4 | [Storage & Data](04-storage-data.md) | Reason about persistent data, HA Postgres, and backups | PV/PVC/CSI, Longhorn, CloudNativePG, MinIO, Redis |
| 5 | [Scaling & Scheduling](05-scaling-scheduling.md) | Make workloads elastic and control where pods land | HPA, VPA/Goldilocks, KEDA, affinity, PDBs |
| 6 | [Observability](06-observability.md) | Instrument, query, and correlate metrics/logs/traces | Prometheus/PromQL, Grafana, Loki, Tempo, Alloy |
| 7 | [Security & Governance](07-security-governance.md) | Layer admission control, runtime detection, and secrets | Kyverno, Falco, Trivy, kube-bench, Vault, ESO |
| 8 | [Release & Ops](08-release-ops.md) | Ship safely (canary), manage images, and run backups/DR | Argo Rollouts, Spegel, cert-manager, Velero |

### If you're short on time — pick a track
- **"I have one weekend."** Modules **1** (architecture) + **3** (GitOps). These two are the most
  foundational *and* the most-asked in interviews. You'll understand 60% of the system.
- **"Interview next week."** Do every module's **Check yourself** section, plus the **labs** for 1,
  2, 3, and 5. Then read *Tell this story in an interview* below.
- **"I want a certification."** See the cert map next.

---

## Map to certifications

These are the industry's standard Kubernetes certs (great résumé signals). Your modules cover most
of the curriculum because this cluster *is* the curriculum.

| Cert | What it proves | Lean on modules |
|---|---|---|
| **CKAD** (Application Developer) | Deploy/manage apps on K8s | 3, 4, 5, 8 (+ core objects in 1) |
| **CKA** (Administrator) | Operate a cluster | 1, 2, 4, 5 (+ RBAC/etcd backup from 7, 8) |
| **CKS** (Security Specialist) | Secure a cluster (needs CKA first) | 7 (+ network policy from 2, supply chain from 8) |

All three are hands-on, in-a-terminal exams — which is exactly how these modules teach. Practice the
labs against your cluster and you're practicing for the exam.

---

## Tell this story in an interview

Your biggest advantage: **you have war stories from a real system**, not just tutorial knowledge.

**The 60-second pitch:** *"I built a production-grade Kubernetes platform from bare metal — Talos
Linux on Proxmox, provisioned with Terraform, everything reconciled by Argo CD from a single Git
repo. It runs the full observability stack (Prometheus/Loki/Tempo), a security/governance tier
(Kyverno, Falco, Trivy, Vault), distributed storage with Longhorn, and a demo app exercising HA
Postgres, KEDA scale-to-zero, and canary rollouts. Then I proved it was reproducible by tearing it
down and rebuilding it from `terraform apply` — which surfaced seven real bugs I fixed."*

**Then go deep on a story** (interviewers love these — they're in [the Resilience Report](../resilience-report.md)
and [gotchas](../talos-gotchas.md)):
- *"An MTU misconfig caused five symptoms that looked unrelated until I spotted the pattern."* →
  shows debugging from first principles (Module 2).
- *"etcd thrashed its page cache and took the control plane down; I recovered it with a
  quorum-preserving rolling RAM bump."* → shows you understand the control plane (Module 1).
- *"Spegel's catch-all mirror hijacked my in-cluster registry and broke image pulls on a fresh
  build."* → shows you understand the container supply chain (Module 8).
- *"I mass-deleted pods on an I/O-wedged node and made it worse — here's what I learned about
  cordon vs. delete."* → shows honesty + operational judgment (Module 5/7).

**What this project demonstrates to a hiring manager:** IaC, GitOps, the full observability triad,
policy-as-code, secrets management, autoscaling, storage/stateful workloads, progressive delivery,
and disaster recovery — i.e. the actual day-to-day of Platform/SRE/DevOps roles.

---

## Where this can take you

The skills here map directly to **Platform Engineer**, **Site Reliability Engineer (SRE)**, **DevOps
Engineer**, and **Cloud/Infrastructure Engineer** roles. The cloud-managed equivalents you'll meet on
the job: EKS/GKE/AKS (managed Kubernetes), Karpenter/Cluster Autoscaler (scaling nodes), and the same
Argo/Prometheus/Grafana/Vault tools you already run here — so this knowledge transfers straight to
AWS/GCP/Azure shops.

**After the modules:** pick one tool you loved and go contribute to it or its docs; redeploy this
cluster on a cloud VM to compare managed vs. self-hosted; and keep the cluster alive as your personal
lab — the best portfolio piece is one you can demo live.

---

*This curriculum was generated against the repo at the time of writing; commands and file paths
reference the real cluster. If something has drifted, the source of truth is always the live cluster
+ the manifests in this repo.*
