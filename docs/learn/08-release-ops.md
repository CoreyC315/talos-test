# Module 8: Release Engineering & Operations — Ship, Cache, Back Up

> Building a cluster is one thing; *operating* it day after day without taking it down is the job. This module is about the unglamorous-but-decisive half of platform engineering: shipping a new app version so safely it rolls itself back if it misbehaves, getting your container images onto nodes fast and reliably, keeping TLS certificates fresh without anyone touching them, restarting pods automatically when their config changes, and — when something truly goes wrong — restoring the whole thing from a backup. After this module you'll be able to run a canary rollout with automated metric analysis, explain your image supply chain end to end, and execute a disaster-recovery drill on your own cluster.

## The big picture

Everything in earlier modules got the cluster *standing up*. This module is the **operations loop** that runs forever after: change → ship safely → observe → (keep or roll back) → back up. Five problems live here, each with a dedicated tool:

- **How do I deploy a risky change without a big-bang outage?** → **Argo Rollouts** (progressive delivery: canary / blue-green + analysis).
- **Where do my app's container images come from, and how do nodes get them fast?** → the **image supply chain** (Docker build → in-cluster **registry** → **Talos Image Factory** for the OS image itself) plus **Spegel**, a peer-to-peer cache so nodes pull from each other.
- **How do I get TLS certs everywhere without manually renewing them?** → **cert-manager**.
- **When a ConfigMap or Secret changes, how do pods pick it up?** → **Reloader**.
- **When I lose data or a whole namespace, how do I get it back?** → **Velero** (app-level backup) + **etcd snapshots** (cluster-state backup) + an **off-site NAS time-capsule**.

```
   developer
      │  docker buildx build → crane push
      ▼
 ┌──────────────┐   image pulled by node    ┌───────────────────────────┐
 │ in-cluster   │◄──────────────────────────│ kubelet / containerd      │
 │ registry     │                           │   ▲  (Spegel: peer cache)  │
 │ .23:5000     │                           │   └── pull from a NEIGHBOUR │
 └──────────────┘                           └───────────────┬───────────┘
                                                             ▼
   git push (new image tag)  ──►  Argo CD  ──►  Argo Rollout (ks-api)
                                                  25%→analysis→50%→analysis→100%
                                                  (Prometheus says "bad" → auto-rollback)
                                                             │
                              cert-manager ── issues *.nip.io TLS ──► Gateway
                              Reloader ── ConfigMap/Secret changed? ──► restart pods
                                                             │
   DR:  Velero → MinIO   +   talosctl etcd snapshot   +   backup-to-nas.sh → Synology
```

The OS image itself (Talos) comes from the **Image Factory** — that's the supply chain one layer *below* your app images, and it's covered here too because "what's in the node image" is a release-engineering decision.

---

## Tools in this module

### Argo Rollouts — deploy a new version gradually and roll back automatically if metrics go bad

- **What it is / mental model:** A drop-in replacement for the built-in Kubernetes `Deployment` that adds **progressive delivery** — shifting traffic to a new version in *steps* instead of all at once, and *automatically aborting* if the new version looks unhealthy. Think of it like a restaurant testing a new dish: instead of putting it on every plate tonight, you serve it to 1 table in 3, check the reviews, then 2 tables in 3, check again, then everyone. If the reviews are bad you pull it immediately. A `Deployment` does a "rolling update" but has **no idea whether the new pods are actually *good*** — it only checks that they pass their readiness probe. Argo Rollouts adds the missing judgment: it queries Prometheus and decides.
- **How it works:** You write a `Rollout` resource (same shape as a `Deployment`, but `kind: Rollout`) with a **strategy**. Two strategies exist:
  - **Canary** (what this repo uses): keep the old ReplicaSet running, bring up a few new pods, and shift a *weight* of traffic to them in steps (`setWeight: 34` → `pause` → `analysis` → `setWeight: 67` → …). With a service mesh you can split traffic precisely; without one (this cluster), the weight is approximated by the **ratio of new-to-old pods** behind the Service — "ReplicaSet-based canary weights, no mesh needed."
  - **Blue-green** (*not* used here, but interview-relevant): bring up a *full* second copy ("green"), test it on a preview Service, then flip 100% of traffic at once and keep "blue" around for instant rollback. Canary = gradual; blue-green = instant cutover with a warm standby.
  - An **`AnalysisTemplate`** is a reusable health check: a named set of Prometheus queries with pass/fail conditions. During a rollout, an `analysis` step spawns an **`AnalysisRun`** that polls those queries; if a `failureLimit` is hit, the rollout **aborts and rolls back** to the previous ReplicaSet. The controller drives the whole dance.
- **In THIS cluster:**
  - `workloads/kubeshowcase/api.yaml` — the `ks-api` `Rollout` (lines 3–102), the `AnalysisTemplate` named `api-health` (lines 116–147). The steps are `setWeight: 34 → pause 60s → analysis → setWeight: 67 → pause 60s → analysis` (line 20–30). The analysis aborts if **error rate > 5%** (`successCondition: result[0] < 0.05`, line 126) or **p95 latency > 500ms** (`result[0] < 0.5`, line 138), queried against the in-cluster Prometheus (line 130).
  - The controller is installed by `apps/workload-operators/argo-rollouts.yaml` (Helm chart `argo-rollouts` v2.41.0; the web dashboard is disabled — "RAM is precious", line 23 — so you use the `kubectl-argo-rollouts` CLI plugin).
  - Live:
    ```bash
    export KUBECONFIG=$PWD/terraform/.kubeconfig
    kubectl argo rollouts get rollout ks-api -n kubeshowcase
    ```
    Look for `Status: ✔ Healthy`, the `Strategy: Canary`, the step list, and a single live ReplicaSet at 100% weight when stable.
- **Job relevance:** "What's the difference between canary and blue-green?" and "how would you roll back automatically?" are *extremely* common SRE/platform interview questions — the phrase to know is **progressive delivery**, and the killer detail is **metric-driven rollback** (don't just shift traffic — *measure* and abort). Maps to **CKAD** (Deployments/rollouts) conceptually; Argo Rollouts itself isn't on any CNCF cert, but the concept is gold for any "how do you ship safely" discussion.
- **Learn it:**
  - argo-rollouts.readthedocs.io — read **"Concepts"**, then **"Canary"**, **"BlueGreen"**, and **"Analysis & Progressive Delivery"**.
  - kubernetes.io docs — search **"Deployment rolling update"** to contrast the built-in behavior with what Rollouts adds.
  - The `kubectl-argo-rollouts` plugin docs (same site) — search **"Kubectl Plugin"** for `get`, `promote`, `abort`, `undo`.

### The image supply chain — where your container images and node OS image come from

- **What it is / mental model:** Two separate supply chains that people often blur together:
  1. **App image supply chain:** your source code → a **Docker image** → stored in a **registry** → pulled by nodes. A registry is just a web server that speaks the OCI distribution API (`/v2/...`) — a "warehouse for container images."
  2. **Node OS image supply chain (Talos Image Factory):** Talos is *immutable* — you don't install packages on a running node; you build a complete OS image with exactly the extensions you want and boot it. The **Image Factory** is Sidero's hosted service that bakes a custom image from a **schematic** (a small YAML listing the extensions) and gives you back a content-addressed **schematic ID**.
  Analogy: the app registry is your local grocery for *ingredients* (images you cook with); the Image Factory is the *appliance factory* that builds the kitchen itself (the OS the nodes run).
- **How it works:**
  - **Build & push:** `docker buildx build --platform linux/amd64` produces an image; `crane push` uploads it to the registry. `crane` is a daemonless registry client (no Docker config needed), and `--insecure` lets it talk **plain HTTP** to the homelab registry. Each push records the **digest** (`sha256:...`), the immutable content hash, in a lockfile.
  - **In-cluster registry:** a single `registry:3.0.0` pod. Two clever hardening choices: it's **pinned to worker-1** (a stable, un-congested host) and exposes a **`hostPort: 5000`** so pulls travel the **physical LAN** at `192.168.1.23:5000` — *bypassing* the Cilium pod overlay and load-balancer indirection, which are slower/flakier under load. Storage is a plain **`hostPath`** dir, not Longhorn, because the registry is a *rebuildable cache* — you don't want fancy replicated storage fighting you over a throwaway image cache.
  - **Talos `registries.mirrors`:** the Talos machine config tells containerd "when you see `192.168.1.23:5000`, use plain HTTP." That's why app manifests can reference `192.168.1.23:5000/ks-api:1.0.0` directly.
  - **Image Factory schematic:** the schematic lists official extensions; the Factory returns a **schematic ID** (a 64-char hash) used to construct the installer image URL `factory.talos.dev/installer/<ID>:<talos-version>`. Bumping the Talos version changes only the `:tag`; the *same schematic ID* keeps your extensions.
- **In THIS cluster:**
  - `platform/registry/registry.yaml` — the registry Deployment; note `hostPort: 5000` (line 36), `nodeSelector: worker-1` (line 28), `hostPath: /var/lib/ks-registry` (line 58). The header comment explains *why* each choice was made.
  - `load-and-chaos/build-and-push.sh` — the build pipeline: loops over `api worker frontend pgdump`, `docker buildx build` → `docker save` → `crane push --insecure` → records `crane digest` into `workloads/kubeshowcase/images.lock`.
  - `talos/schematic.yaml` — schematic ID `7d1fa2e0…a092`, extensions `iscsi-tools`, `util-linux-tools` (both for Longhorn), `qemu-guest-agent` (Proxmox), `intel-ucode` (the i7-4770 hosts). The installer URL is in the comment at line 4.
  - App images reference the registry directly, e.g. `workloads/kubeshowcase/api.yaml:72` → `image: 192.168.1.23:5000/ks-api:1.0.0`.
  - Live:
    ```bash
    # What images does the registry hold? (plain HTTP, via the cluster)
    kubectl -n registry exec deploy/registry -- wget -qO- http://localhost:5000/v2/_catalog
    # Where the registry pod actually runs (should be worker-1):
    kubectl -n registry get pod -o wide
    ```
    The catalog should list `ks-api`, `ks-worker`, `ks-frontend`, `ks-pgdump`.
- **Job relevance:** "Walk me through how a code change becomes a running pod" is a staple. Know the words **image digest vs tag** (tags move, digests are immutable — pin digests in production), **registry / OCI**, and **insecure registry / mirror config**. For Talos shops specifically, **immutable OS + Image Factory schematics** is a strong, differentiating talking point. Touches **CKS** (image provenance, supply-chain security, image scanning).
- **Learn it:**
  - distribution/distribution docs (the registry) — search **"registry distribution OCI"**; and the **OCI Distribution Spec** for the `/v2/` API.
  - github.com/google/go-containerregistry — the **`crane`** README for `push`/`digest`/`copy`.
  - factory.talos.dev and talos.dev — search **"Talos Image Factory"** and **"system extensions"**.

### Spegel — make image pulls fast and resilient by letting nodes pull from each other

- **What it is / mental model:** A **peer-to-peer (P2P) image cache** that runs on every node. Normally each node pulls every image from the upstream registry. Spegel notices that *another node in the cluster already has that image layer* and pulls it from that neighbour over the local network instead. Analogy: instead of six roommates each driving to the store for the same milk, the first one buys it and the rest grab it from the fridge. It also keeps you running when the upstream registry is briefly down — if a peer has the layer, you're fine.
- **How it works:** Spegel runs as a DaemonSet, talks to each node's **containerd** socket to learn which image layers are already on disk, advertises them to peers (a distributed hash table), and configures containerd's **registry mirror hosts directory** so a pull first tries peers, then falls back to the real registry. The subtle, hard-won detail in this repo: Spegel *manages the entire* containerd hosts dir, so if you let it default to "mirror everything" it also intercepts the plain-HTTP in-cluster registry (which it can't proxy) and pulls **fail**. The fix is to explicitly list which registries to mirror — including the in-cluster one with an `http://` scheme so containerd writes a working HTTP fallback.
- **In THIS cluster:**
  - `apps/platform/spegel.yaml` — Helm chart `spegel` 0.7.1. Key fields: `containerdSock` and `containerdRegistryConfigPath` for Talos paths (lines 19–20), the explicit `mirroredRegistries` list (lines 26–35) covering docker.io / ghcr.io / registry.k8s.io / quay.io **and** `http://192.168.1.23:5000`, `prependExisting: true` (keep Talos's own mirror entries, line 37), and `hostPort: 29999` (line 40). The long comments (lines 21–35) are a great case study in a real debugging war story.
  - Live:
    ```bash
    kubectl -n spegel get pods -o wide          # one pod per node, all Running
    kubectl -n spegel logs ds/spegel | grep -i "advertis\|mirror\|peer" | head
    ```
    You should see 6 pods (one per node) and log lines about advertising/resolving layers.
- **Job relevance:** A great "I optimized something real" story — bandwidth savings and **registry-outage resilience**. Demonstrates you understand the layer below kubelet: **containerd**, **registry mirrors / hosts.toml**, and image-pull mechanics. Not on a cert, but adjacent to CKA networking/troubleshooting.
- **Learn it:**
  - spegel.dev — read **"Introduction"** and **"Getting Started"**, and the section on **containerd mirror configuration**.
  - containerd docs — search **"registry configuration hosts.toml"** to understand the mirror mechanism Spegel programs.

### cert-manager — issue and auto-renew TLS certificates so nobody touches them by hand

- **What it is / mental model:** A controller that treats a **TLS certificate as a Kubernetes resource you declare**, then keeps it valid forever — issuing it, storing it in a Secret, and **renewing it before it expires**, automatically. Analogy: a subscription that mails you a fresh passport before the old one expires, so you never get stuck at the border. Before cert-manager, "the cert expired at 2am and the site went down" was a classic outage. Now you write a `Certificate` and forget it.
- **How it works:** You define an **Issuer**/`ClusterIssuer` (where certs come from — Let's Encrypt via ACME in the cloud, or a private CA in a homelab) and a **`Certificate`** (what you want: DNS names, duration, `renewBefore`). cert-manager generates a key + CSR, gets it signed by the issuer, and writes the result into a Secret. This repo builds a realistic **PKI chain**: a self-signed *bootstrap* issuer → a 10-year **root CA** → a 5-year **intermediate CA** → the `homelab-ca` ClusterIssuer that signs all leaf certs. You trust the *root* once on your workstation, and leaves can rotate freely underneath it — exactly how real corporate CAs work.
- **In THIS cluster:**
  - `apps/platform/cert-manager.yaml` — installs the controller (Helm `cert-manager` v1.20.2, CRDs enabled) and a second App that syncs the config from `platform/cert-manager/`.
  - `platform/cert-manager/ca-chain.yaml` — the full bootstrap → root → intermediate → `homelab-ca` chain (lines 3–59).
  - `platform/gateway/gateway.yaml` — the **`wildcard-tls` Certificate** for `*.192.168.1.27.nip.io` (lines 3–17): `duration: 2160h` (90d), `renewBefore: 360h` (15d), issued by `homelab-ca`. The Gateway's HTTPS listener references the resulting `wildcard-tls` Secret (lines 34–37). That's why `https://app.192.168.1.27.nip.io` has a working cert.
  - Live:
    ```bash
    kubectl get clusterissuer                 # homelab-ca / homelab-root / selfsigned-bootstrap, all READY=True
    kubectl get certificate -A                 # wildcard-tls + the two CAs, READY=True
    kubectl -n gateway describe certificate wildcard-tls | grep -A3 "Status\|Not After"
    ```
    Look for `READY: True` and a `Not After` ~90 days out.
- **Job relevance:** Universally used; interviewers ask **"how do you manage TLS at scale?"** (answer: cert-manager + ACME or a private CA), the **issuer vs certificate** split, and **automatic renewal**. Know **ACME / Let's Encrypt** and **DNS-01 vs HTTP-01 challenges**. Strongly tied to **CKS** (the "secure ingress / TLS" domain).
- **Learn it:**
  - cert-manager.io — read **"Concepts → Issuers/Certificates"**, then **"Configuration → CA"** and **"ACME"**.
  - kubernetes.io — search **"Manage TLS Certificates in a Cluster"** for the underlying CSR API cert-manager automates.

### Reloader — restart pods automatically when their ConfigMap or Secret changes

- **What it is / mental model:** Kubernetes has a famous gap: if you change a ConfigMap or Secret, **pods do not automatically restart to pick it up** (env vars and `envFrom` values are baked in at start time). Reloader is a tiny controller that watches your config objects and triggers a rolling restart of any workload annotated to care. Analogy: a smoke detector wired to the doorbell — when the config "changes," it nudges the right rooms to wake up. Without it you're doing manual `kubectl rollout restart` and hoping you didn't forget one.
- **How it works:** Reloader watches ConfigMaps/Secrets cluster-wide. Any Deployment/Rollout/StatefulSet/DaemonSet carrying `reloader.stakater.com/auto: "true"` (auto-detect every config it references) — or a targeted `configmap.reloader.stakater.com/reload: <name>` — gets restarted (it bumps a pod-template annotation, which the workload controller treats as a change → rolling update). It cooperates with Argo Rollouts: a "reload" on a `Rollout` runs through the *canary* steps, not a blind restart.
- **In THIS cluster:**
  - `apps/workload-operators/reloader.yaml` — Helm chart `reloader` 2.2.12.
  - `workloads/kubeshowcase/api.yaml:10` — the `ks-api` Rollout has `reloader.stakater.com/auto: "true"` ("roll pods when ks-config / ks-sops-demo change"). Same annotation on `ks-worker` (`workloads/kubeshowcase/worker.yaml:9`).
  - Live:
    ```bash
    kubectl -n reloader get pods                         # reloader-... Running
    kubectl -n reloader logs deploy/reloader-reloader | tail -20
    ```
    Logs show it watching for changes; you'll trigger an actual reload in the lab.
- **Job relevance:** A precise way to show you understand a real K8s footgun: **ConfigMap/Secret changes don't propagate to running pods by default.** Interviewers like the follow-up "how do you roll config safely?" (answer: checksum/annotation pattern, or Reloader). Conceptually **CKAD** (configuration). Bonus: know the manual alternative — putting a config **checksum annotation in the pod template** so any change forces a new ReplicaSet.
- **Learn it:**
  - github.com/stakater/Reloader — the README; search **"Reloader annotations"** for `auto` vs targeted.
  - kubernetes.io — search **"ConfigMap mounted as volume auto-update"** to understand *which* config types update live (mounted files do, env vars don't) and why Reloader is needed for env-style config.

### Backup & DR — restore an app, restore cluster state, and survive losing the whole rack

- **What it is / mental model:** Three layers of "undo," because they protect different things:
  1. **Velero** — backs up **Kubernetes objects + persistent volume data** for a namespace, to S3-compatible storage. This is your "I deleted the app / corrupted its data" restore. Analogy: Time Machine for a folder.
  2. **etcd snapshot** — backs up the **cluster's brain**: etcd is the database holding *every* Kubernetes object. A snapshot is the canonical recovery point if the control plane itself is destroyed. Analogy: a full image of the filing cabinet, not just one drawer.
  3. **Off-site NAS time-capsule** — bundles the git repo, a cluster snapshot, an etcd snapshot, and the *encrypted* crown jewels (age key, kube/talosconfig, Terraform state) into one timestamped tarball shipped to a Synology NAS. Analogy: a sealed go-bag in a fireproof safe at a *different* address — so you can rebuild even if the whole homelab is gone.
- **How it works:**
  - **Velero** runs a server + a per-node **node-agent**. `velero backup create` snapshots the API objects in a namespace and, with **CSI data movement** (`features: EnableCSI`, `defaultSnapshotMoveData: true`), copies the *actual PV bytes* into object storage. Restore re-creates objects and re-hydrates volumes. Here the storage target is in-cluster **MinIO** (an S3 server) via the AWS plugin pointed at `s3Url: http://minio.minio.svc...`.
  - **etcd snapshot** is a single talosctl call: `talosctl -n <cp-ip> etcd snapshot file.snap`. To restore, Talos boots a control-plane node in *recovery* mode from that file.
  - **NAS capsule:** the script does best-effort `kubectl`/`talosctl` dumps, takes an etcd snapshot, AES-encrypts the secrets, tars it, and ships it to the NAS via a temporary in-cluster pod mounting the NFS export (clever: no `sudo` needed on your laptop).
- **In THIS cluster:**
  - `apps/platform/velero.yaml` — Velero Helm 12.0.2 + AWS plugin v1.13.0; backup-location `default` → MinIO bucket `velero`; `EnableCSI`, `defaultSnapshotMoveData: true`, `deployNodeAgent: true`.
  - `load-and-chaos/runbooks/dr-velero.md` — the full drill: seed a `dr-canary` row → backup → **delete the namespace** → restore → verify the row survived and CNPG Postgres bootstraps from the restored PVC.
  - `load-and-chaos/runbooks/upgrade-talos-k8s.md` — "**etcd snapshot first (always, before any CP change)**" at line 8; the `talosctl … etcd snapshot` command at line 9.
  - `load-and-chaos/backup-to-nas.sh` — the time-capsule (NAS `192.168.1.210:/volume1/backups`); contents listed at lines 7–12; etcd snapshot at line 64; encrypted secrets at lines 71–77.
  - Live (non-destructive):
    ```bash
    velero version                              # client + server
    velero backup-location get                  # default → MinIO bucket "velero", PHASE Available
    velero backup get                           # existing backups
    ```
    `default` should read `Available`.
- **Job relevance:** **The single most reliable interview area in this module.** "What's your backup and DR strategy?", "**RTO vs RPO**" (Recovery Time / Recovery Point Objective — how fast you recover vs how much data you can lose), "what does an etcd snapshot protect vs Velero?", "where do you store backups and is the store itself a single point of failure?" **Restoring etcd from a snapshot is explicitly on the CKA exam.** Velero and the 3-2-1 backup rule are bread-and-butter SRE.
- **Learn it:**
  - velero.io — read **"How Velero Works"**, **"Backup Reference"**, **"CSI Snapshot Data Movement"**, **"Disaster recovery"**.
  - kubernetes.io — search **"Operating etcd clusters for Kubernetes"** → the **"Snapshotting / Restoring"** section (CKA-relevant).
  - talos.dev — search **"etcd maintenance"** / **"Disaster recovery"** for the Talos-specific restore flow.

---

## Hands-on lab (on YOUR cluster)

All of these start with:

```bash
cd /Users/ccampbell/dev/talos-test
export KUBECONFIG=$PWD/terraform/.kubeconfig
export TALOSCONFIG=$PWD/talos/clusterconfig/talosconfig
```

### Lab 1 — Inspect a live Rollout and its analysis (read-only)

```bash
kubectl argo rollouts get rollout ks-api -n kubeshowcase
kubectl -n kubeshowcase get analysistemplate api-health -o yaml | sed -n '1,40p'
```
**Success:** the rollout prints `Status: ✔ Healthy`, `Strategy: Canary`, the 5 steps (`setWeight 34 → pause → analysis → setWeight 67 → …`), and a single ReplicaSet at 100%. The AnalysisTemplate shows the two Prometheus queries with `successCondition` thresholds (`< 0.05`, `< 0.5`).

### Lab 2 — Drive a canary rollout and watch the analysis run

Trigger a new revision *without* changing the image (so it's safe and reversible) by patching a harmless annotation, then watch the canary progress live:

```bash
kubectl -n kubeshowcase patch rollout ks-api --type merge \
  -p '{"spec":{"template":{"metadata":{"annotations":{"lab/touched":"'$(date +%s)'"}}}}}'

# Watch the canary climb 34% → analysis → 67% → analysis → 100% (Ctrl-C to stop watching):
kubectl argo rollouts get rollout ks-api -n kubeshowcase --watch
```
**Success:** you see a *canary* ReplicaSet appear, the status go to `Progressing`, an **`AnalysisRun`** spawn (`kubectl -n kubeshowcase get analysisrun`) and report `Successful`, then `Healthy` again. To jump the queue: `kubectl argo rollouts promote ks-api -n kubeshowcase`. To bail out and revert: `kubectl argo rollouts abort ks-api -n kubeshowcase` then `... promote` (or `undo`). Because the image never changed, the end state is identical to the start.

### Lab 3 — See the image supply chain end to end

```bash
# 1. Where do the app pods say their image lives?
kubectl -n kubeshowcase get rollout ks-api \
  -o jsonpath='{.spec.template.spec.containers[0].image}'; echo
# 2. What's actually in the in-cluster registry?
kubectl -n registry exec deploy/registry -- wget -qO- http://localhost:5000/v2/_catalog; echo
# 3. The recorded digests (immutable hashes) for each image:
cat workloads/kubeshowcase/images.lock
# 4. The Talos OS image schematic that built the nodes:
cat talos/schematic.yaml
```
**Success:** step 1 prints `192.168.1.23:5000/ks-api:1.0.0`; step 2 lists `ks-api`, `ks-worker`, `ks-frontend`, `ks-pgdump`; step 3 shows `…@sha256:…` digests; step 4 shows the 4 system extensions. You've now traced an image from manifest → registry → digest, and the *node* image to its schematic.

### Lab 4 — Prove Reloader restarts pods on config change

```bash
# Note the current ks-api pods and revision:
kubectl -n kubeshowcase get pods -l app=ks-api
# Add a throwaway key to the watched ConfigMap:
kubectl -n kubeshowcase patch configmap ks-config --type merge \
  -p '{"data":{"LAB_NUDGE":"'$(date +%s)'"}}'
# Watch Reloader notice it and roll the pods:
kubectl -n reloader logs deploy/reloader-reloader --since=2m | grep -i ks-config
kubectl argo rollouts get rollout ks-api -n kubeshowcase --watch
```
**Success:** Reloader's log shows it detected the `ks-config` change and triggered `ks-api`; because `ks-api` is a Rollout, the restart runs through the **canary steps**, not a blind kill. Clean up: `kubectl -n kubeshowcase patch configmap ks-config --type json -p '[{"op":"remove","path":"/data/LAB_NUDGE"}]'`.

### Lab 5 — Inspect TLS and confirm auto-renewal is configured

```bash
kubectl get clusterissuer
kubectl -n gateway describe certificate wildcard-tls | grep -E "Common Name|Not After|Renewal Time|Status"
# See the real cert the browser gets, signed by your homelab CA:
curl -skv https://app.192.168.1.27.nip.io/healthz 2>&1 | grep -E "subject:|issuer:|expire"
```
**Success:** the three ClusterIssuers are `READY=True`; the certificate shows `Common Name: *.192.168.1.27.nip.io`, a `Not After` ~90 days out, and a `Renewal Time` ~15 days before that. The `curl` output shows the cert issued by your *KubeShowcase Intermediate CA*.

### Lab 6 — A non-destructive backup drill (etcd snapshot + Velero backup)

This makes backups but does **not** delete anything (skip the destroy/restore steps from the runbook unless you want the full drill):

```bash
# Cluster brain → a portable snapshot file:
talosctl -n 192.168.1.20 etcd snapshot etcd-$(date +%Y%m%d).snap
ls -lh etcd-*.snap

# App namespace → Velero backup into MinIO, then inspect it:
velero backup-location get
velero backup create ks-lab-$(date +%H%M) --include-namespaces kubeshowcase --wait
velero backup describe $(velero backup get -o name | head -1 | cut -d/ -f2) --details | sed -n '1,30p'
```
**Success:** you get an `etcd-YYYYMMDD.snap` file (a few MB); the Velero backup ends `Phase: Completed` with item counts and a CSI data-movement section. The full delete→restore drill lives in `load-and-chaos/runbooks/dr-velero.md` — do it only when you can afford to recreate `kubeshowcase`. Clean up backups with `velero backup delete ks-lab-XXXX --confirm` and `rm etcd-*.snap` (after copying them somewhere safe if you want).

---

## Check yourself

1. **What does an Argo Rollouts canary do that a built-in Deployment rolling update does not?**
   *It measures the new version (via metric analysis) and automatically aborts/rolls back; a Deployment only checks readiness probes, not whether the version is actually healthy.*
2. **Canary vs blue-green — one-line difference?**
   *Canary shifts traffic gradually in weighted steps; blue-green brings up a full second copy and flips 100% at once with the old copy kept warm for instant rollback.*
3. **In `api-health`, what two signals abort the `ks-api` rollout, and at what thresholds?**
   *5xx error rate ≥ 5% (`result < 0.05` fails) and p95 latency ≥ 500ms (`result < 0.5` fails), queried from Prometheus.*
4. **Why does the in-cluster registry use a `hostPort` and `hostPath` instead of a Service + Longhorn?**
   *`hostPort` routes pulls over the physical LAN, bypassing the slower/flakier Cilium overlay + LB indirection; `hostPath` keeps a rebuildable image cache local and fast, avoiding Longhorn reattach races.*
5. **What problem does Spegel solve, and what does it talk to on each node?**
   *It caches images peer-to-peer so nodes pull layers from each other (faster + survives a registry outage); it talks to each node's containerd socket and programs its registry-mirror hosts dir.*
6. **Why does changing a ConfigMap not restart pods, and what fixes it here?**
   *Env vars / `envFrom` values are baked in at container start; Reloader watches config objects and rolls annotated workloads (`reloader.stakater.com/auto: "true"`) to pick up changes.*
7. **What does an etcd snapshot protect that a Velero backup does not (and vice-versa)?**
   *etcd snapshot = the whole cluster's object state / control-plane brain (for rebuilding the cluster); Velero = a namespace's objects + PV data (for restoring an app and its data). You want both.*
8. **Define RTO and RPO, and which tool/practice in this repo improves each.**
   *RTO = how fast you recover (Velero restore speed, Talos one-command etcd recovery); RPO = how much data you can lose (CNPG continuous WAL archiving → seconds; periodic etcd snapshots / NAS capsules set the floor).*

---

## Where this fits in the path

**Before:** the app/workload module (Deployments, Services, ConfigMaps/Secrets, the Gateway/HTTPRoute) and the GitOps module (Argo CD sync waves) — Rollouts and Reloader assume you know those primitives. **After:** observability & SLOs (the Prometheus metrics that *power* the rollout analysis you just used) and security/supply-chain hardening (image signing/scanning, CKS) — the natural next step once you can ship and restore confidently.
