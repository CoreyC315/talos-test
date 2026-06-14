# Module 7: Security & Governance — Guardrails, Policy & Secrets

> Security is the part of Kubernetes that separates a hobby cluster from a production one — and it's
> the area where SRE/platform interviews dig hardest, because a misconfigured pod or a leaked secret
> is how real companies get breached. After this module you'll be able to read and write RBAC, reason
> about Pod Security Standards, author policy-as-code with Kyverno, interpret vulnerability and
> CIS-benchmark reports, and explain end-to-end how a secret travels from a vault into a running pod
> without ever touching Git. You already run all of this live; this module turns "it's installed" into
> "I understand exactly what each piece does and why."

## The big picture

Cluster security is layered. No single tool makes you "secure" — you stack **preventive** controls
(stop bad things from being admitted), **detective** controls (notice bad things that slip through or
happen at runtime), and **secrets management** (keep credentials out of YAML and out of Git).

```
                       4 Cs:  Cloud  →  Cluster  →  Container  →  Code
                                                 (this module lives in Cluster + Container)

   ┌─────────────────────────── PREVENTIVE (admission time) ───────────────────────────┐
   │  RBAC            who is allowed to call the API at all                              │
   │  Pod Security    built-in baseline: can this pod be privileged / run as root?       │
   │  Kyverno         your custom rules: validate / mutate / generate on every apply     │
   └────────────────────────────────────────────────────────────────────────────────────┘
                                          │  (object is admitted, pod now runs)
                                          ▼
   ┌─────────────────────────── DETECTIVE (runtime + scanning) ────────────────────────┐
   │  Trivy Operator  scans running images + configs for CVEs and misconfig             │
   │  kube-bench      audits node config against the CIS benchmark                       │
   │  Falco           watches live syscalls (eBPF) and alerts on suspicious behavior     │
   └────────────────────────────────────────────────────────────────────────────────────┘
                                          │
                                          ▼
   ┌─────────────────────────── SECRETS (out-of-band) ─────────────────────────────────┐
   │  Vault           stores secrets, issues short-lived auth, KV engine                 │
   │  External Secrets syncs Vault → native Kubernetes Secret objects                    │
   └────────────────────────────────────────────────────────────────────────────────────┘
```

In this repo every one of these is deployed by Argo CD as an `Application` in `apps/security/`, all on
**sync-wave 5** (after the platform basics, before the demo app). The Kyverno and ESO config that you
write lives in `security/`. Read this module top to bottom; each tool builds on the one before it.

## Tools in this module

### The 4 Cs of cloud-native security — a mental model for *where* a control belongs

- **What it is / mental model:** The "4 Cs" (popularized by the CNCF and the Kubernetes docs) are four
  nested layers of defense: **Cloud → Cluster → Container → Code**. Think of it like a castle: the
  Cloud is the land and moat (your Proxmox hosts, network, firewall), the Cluster is the castle walls
  and gatekeepers (the API server, RBAC, admission control, Pod Security), the Container is each room's
  locked door (image provenance, non-root, dropped capabilities, read-only filesystem), and the Code is
  what's inside the room (your app's dependencies, input validation, secrets handling). The key insight:
  an inner layer can only ever be as safe as the layer outside it — perfect app code in a privileged
  container on a wide-open cluster is still exposed.
- **How it works:** It's not software, it's a *taxonomy* you use to place a given control. When someone
  says "we have a CVE in our base image," that's the **Container** layer (fix: scan + rebuild — Trivy).
  "A developer service account can delete any namespace" is the **Cluster** layer (fix: RBAC).
  "Our Postgres password is in a committed YAML" is the **Code/secrets** boundary (fix: Vault + ESO,
  or SOPS). Interviewers love this because it forces you to reason about *defense in depth* rather than
  one magic fix.
- **In THIS cluster:** Every tool below maps to a C. Cluster: RBAC (`workloads/kubeshowcase/rbac.yaml`),
  Pod Security labels (visible on namespaces), Kyverno (`security/kyverno/policies/`). Container: Trivy
  Operator, the `restrict-registries` and `require-non-root` Kyverno policies. Code/runtime: Falco
  (`apps/security/falco.yaml`), Vault + ESO. The cluster's restricted demo namespace is the clearest
  example: `kubectl get ns kubeshowcase -o jsonpath='{.metadata.labels}'` shows
  `pod-security.kubernetes.io/enforce: restricted` — Cluster-layer enforcement of Container-layer hygiene.
- **Job relevance:** "Walk me through how you'd secure a Kubernetes cluster" is a near-universal opener.
  The 4 Cs give you a structured, non-rambling answer. Maps conceptually to **CKS** (the whole exam is
  organized around these layers).
- **Learn it:**
  - kubernetes.io → Documentation → Concepts → Security → "Overview of Cloud Native Security" (the
    canonical 4 Cs page).
  - CNCF "Cloud Native Security Whitepaper" (search the cncf.io site for that title).

### Pod Security Standards — the built-in "how privileged can this pod be?" gate

- **What it is / mental model:** Pod Security Standards (**PSS**) are three predefined profiles —
  **privileged** (anything goes), **baseline** (block the well-known dangerous stuff: host networking,
  most host paths, privilege escalation), and **restricted** (lock it down hard: must run non-root, drop
  ALL Linux capabilities, use a seccomp profile, no host namespaces). The **Pod Security Admission**
  controller is the built-in enforcement engine (it replaced the old PodSecurityPolicy). Mental model:
  it's a dress code enforced at the door of each namespace. You label the namespace with the dress code,
  and the bouncer (admission controller) checks every pod against it.
- **How it works:** You don't write rules — you just **label a namespace** with up to three modes:
  `pod-security.kubernetes.io/enforce` (reject violating pods), `/audit` (allow but log), and `/warn`
  (allow but warn the user at apply time), each set to a level (`privileged`/`baseline`/`restricted`).
  Enforcement happens *at admission*: a pod that violates `restricted` is simply refused. This is coarse,
  built-in, and free — it's the floor, and Kyverno (below) is how you go beyond it.
- **In THIS cluster:** The posture is documented in `security/pss/namespaces.md`. The default intent is
  `restricted`; a handful of namespaces get an explicit `privileged` exception for a *concrete* reason
  (Falco needs eBPF + host access, Longhorn needs host devices/iSCSI, Spegel mounts the host containerd
  socket, kube-bench needs `hostPID` + host mounts). Argo CD applies these labels via
  `managedNamespaceMetadata` — see `apps/security/falco.yaml` line 48-51 and `apps/security/kube-bench.yaml`
  line 23-26. Live, you can see the whole posture at a glance:
  ```sh
  export KUBECONFIG=$PWD/terraform/.kubeconfig
  kubectl get ns -o custom-columns='NAME:.metadata.name,ENFORCE:.metadata.labels.pod-security\.kubernetes\.io/enforce'
  ```
  Look for `kubeshowcase → restricted`, `falco/kube-bench/longhorn-system/spegel → privileged`. That's
  the dress code per room.
- **Job relevance:** Extremely common CKS/CKA territory. Expect: "What replaced PodSecurityPolicy?"
  (answer: Pod Security Admission + the three Standards, plus third-party tools like Kyverno/OPA).
  "What does `restricted` require?" (non-root, drop ALL caps, seccomp `RuntimeDefault`, no privilege
  escalation, no host namespaces/paths). Maps to **CKS** and **CKA**.
- **Learn it:**
  - kubernetes.io → search "Pod Security Standards" (the page that lists exactly what each profile blocks).
  - kubernetes.io → search "Enforce Pod Security Standards with Namespace Labels".

### RBAC — who is allowed to do what to the Kubernetes API

- **What it is / mental model:** Role-Based Access Control. Everything in Kubernetes is an API call;
  RBAC decides whether a given **subject** (a user, group, or **ServiceAccount**) may perform a given
  **verb** (get/list/watch/create/update/delete) on a given **resource** (pods, secrets, configmaps…).
  Mental model: a building access-card system. A **Role** is a key that opens certain doors *on one
  floor* (namespace); a **ClusterRole** opens doors *building-wide*. A **RoleBinding** / **ClusterRoleBinding**
  is the act of handing that key to a specific person or robot. No binding = no access; RBAC is
  default-deny.
- **How it works:** Two halves. (1) A `Role`/`ClusterRole` lists `rules` — `apiGroups`, `resources`,
  optionally `resourceNames`, and `verbs`. (2) A `RoleBinding`/`ClusterRoleBinding` connects that role to
  one or more `subjects`. Permissions are purely **additive** — there are no "deny" rules, so least
  privilege means granting the smallest set possible. ServiceAccounts are the identities your *pods* use;
  if a pod mounts its token, the app can call the API with whatever that SA is bound to.
- **In THIS cluster:** `workloads/kubeshowcase/rbac.yaml` is a clean least-privilege exhibit. The
  `ks-api` ServiceAccount sets `automountServiceAccountToken: false` (the app never calls the API, so it
  gets *no* token at all — lines 6-7), and a `Role` named `ks-api-config-reader` grants exactly
  `get`/`watch` on a *single* ConfigMap by name (`resourceNames: [ks-config]`, lines 28-32) — nothing
  else, scoped to the namespace. Live, inspect a real binding and test access:
  ```sh
  kubectl -n kubeshowcase get role,rolebinding
  kubectl -n kubeshowcase describe role ks-api-config-reader
  # The killer RBAC debugging command — "can this identity do X?":
  kubectl auth can-i get configmaps -n kubeshowcase \
    --as=system:serviceaccount:kubeshowcase:ks-api          # -> yes
  kubectl auth can-i delete pods -n kubeshowcase \
    --as=system:serviceaccount:kubeshowcase:ks-api          # -> no
  ```
- **Job relevance:** RBAC is *the* most-tested security topic on **CKA** and **CKS**. You will be asked
  to create a Role + RoleBinding, and to debug "this pod gets a 403." Memorize `kubectl auth can-i ...
  --as=...` — it's the single most useful real-world RBAC command. Know the Role vs ClusterRole and
  RoleBinding vs ClusterRoleBinding matrix cold (a RoleBinding *can* reference a ClusterRole to grant
  cluster-defined permissions within one namespace).
- **Learn it:**
  - kubernetes.io → search "Using RBAC Authorization" (the reference for every field).
  - kubernetes.io → search "Configure Service Accounts for Pods".
  - Practice: `kubectl create role`/`rolebinding --dry-run=client -o yaml` to generate manifests fast.

### Kyverno — policy-as-code admission control (validate / mutate / generate)

- **What it is / mental model:** Kyverno is a Kubernetes-native **policy engine** that runs as an
  **admission webhook** — when any object is submitted to the API server, the server phones Kyverno and
  asks "is this allowed, and do you want to change it?" Mental model: a programmable bouncer you write
  rules for in plain YAML (no new language to learn, unlike OPA/Rego). Pod Security Standards give you
  three fixed dress codes; Kyverno lets you write *your own* arbitrary rules. It does three things:
  **validate** (allow/block/audit based on a pattern), **mutate** (auto-edit the object — e.g. add a
  label), and **generate** (create related objects — e.g. a default NetworkPolicy in every new namespace).
- **How it works:** A `ClusterPolicy` contains `rules`; each rule has a `match`/`exclude` (which
  resources it applies to) and a `validate`/`mutate`/`generate` block. For validation you write a
  **pattern** that the resource must match — Kyverno's pattern language uses wildcards (`*`, `?*`),
  anchors like `=()` ("conditional: if this key exists, it must match"), and `anyPattern` (OR-of-patterns).
  The crucial knob is `validationFailureAction`: **`Audit`** = record a violation in a PolicyReport but
  allow the object; **`Enforce`** = reject it at admission. Kyverno also runs in the **background** to
  re-evaluate *already-existing* resources, populating cluster-wide PolicyReports.
- **In THIS cluster:** The Helm app is `apps/security/kyverno.yaml` (chart 3.8.1, wave 5). It runs four
  controllers — admission, background, cleanup, reports — each at a single replica for this RAM-tight box.
  A deliberately important production detail lives at lines 18-23: `forceFailurePolicyIgnore: enabled`
  makes the webhook **fail-open** — if Kyverno is unreachable, pod creation is *not* blocked. That's only
  safe here *because every policy is `Audit`, not `Enforce`* (a fail-open enforcing webhook would be a
  security hole). The five policies live in `security/kyverno/policies/`:
  - `disallow-latest-tag.yaml` — every image must have an explicit tag, and it must not be `:latest`.
  - `require-non-root.yaml` — `runAsNonRoot: true` (PSS-restricted style, via `anyPattern`).
  - `require-probes.yaml` — Deployments/StatefulSets must have liveness + readiness probes.
  - `require-resources.yaml` — every container must declare CPU + memory requests (so the scheduler can
    pack a tight node).
  - `restrict-registries.yaml` — images only from an allowlist (`docker.io`, `ghcr.io`, `quay.io`,
    `registry.k8s.io`, `factory.talos.dev`, `public.ecr.aws`, and the in-cluster `192.168.1.23:5000`).

  Note all five `exclude` the infra namespaces (kube-system, longhorn-system, etc.) so platform components
  aren't flagged. Live:
  ```sh
  kubectl get cpol                                   # all 5, READY=True
  kubectl describe cpol require-non-root | head -40   # read the rule + failureAction (Audit)
  # See what FAILED a policy across the whole cluster:
  kubectl get policyreport -A | awk '$5>0 || $6>0'    # rows with FAIL/WARN > 0
  ```
  Look for the policies all `Ready=True`, and note `goldilocks` rows with a `FAIL` in the PolicyReport
  (something there trips a policy in Audit mode — proof the engine is actually evaluating workloads).
- **Job relevance:** "How do you enforce org-wide standards on a cluster?" → admission control;
  name-drop Kyverno **and** OPA/Gatekeeper (the two big policy engines) and contrast them (Kyverno =
  YAML-native; Gatekeeper = Rego). Know the validate/mutate/generate triad and the Audit-vs-Enforce
  distinction. Understand *why a fail-open enforcing webhook is dangerous*. Strongly **CKS**.
- **Learn it:**
  - kyverno.io → Documentation → "Writing Policies" (covers pattern anchors `=()`, `anyPattern`, etc.).
  - kyverno.io → "Policy Reports" and "Background scanning".
  - kyverno.io → "Policies" library (a huge catalog of ready-made ClusterPolicies to read and adapt).

### Falco — runtime threat detection by watching syscalls (eBPF)

- **What it is / mental model:** Everything above stops bad things *before* they run. Falco is the
  opposite — it assumes something already got in and watches what containers actually *do* at runtime.
  It's the CNCF runtime-security project: a tripwire on the kernel. Mental model: a security camera with
  motion rules inside every room. RBAC/Kyverno are the locks on the doors; Falco is the alarm that fires
  if someone *inside* a room starts jimmying a window — e.g. "a shell was spawned inside a container,"
  "something wrote to `/etc`," "a process opened an unexpected outbound connection."
- **How it works:** Falco runs a **DaemonSet** (one pod per node) and taps the Linux kernel via
  **eBPF** — a safe, sandboxed way to run small programs *inside* the kernel to observe events. It hooks
  **syscalls** (the calls every program makes to the OS: open a file, exec a binary, connect a socket),
  enriches them with container/Kubernetes metadata, and matches them against a **rules** file. A match
  produces an alert. This cluster uses the **modern eBPF** driver (`driver.kind: modern_ebpf`), which
  needs no kernel module — important on Talos, where you can't just `insmod` things.
- **In THIS cluster:** `apps/security/falco.yaml` (chart 9.1.0, wave 5). Key choices: `modern_ebpf`
  driver (line 18), `json_output: true` (machine-readable alerts), and **falcosidekick** enabled (lines
  27-35) to fan alerts out — here it points at the cluster's Alertmanager
  (`kube-prometheus-stack-alertmanager.monitoring.svc:9093`), so a Falco hit becomes a normal alert
  alongside everything else. The web UI is off to save RAM (line 37). Falco's namespace is labeled
  `pod-security: privileged` (line 51) because eBPF + host visibility require it. Live:
  ```sh
  kubectl -n falco get pods           # a falco-XXXXX per node (each 2/2) + falcosidekick
  kubectl -n falco logs ds/falco -c falco | grep -i '"priority"' | tail -20
  # Trip a rule on purpose (safe, reversible) — spawn an interactive shell in a running pod:
  kubectl -n kubeshowcase exec -it deploy/ks-api -- sh -c 'echo hi'   # may not exist; see lab
  ```
  Falco ships a default rule "Terminal shell in container," so exec'ing into a pod is the classic way to
  watch an alert appear in the falco logs.
- **Job relevance:** "How do you detect a compromised container?" → runtime security; name Falco (the
  CNCF standard) and explain eBPF/syscall monitoring vs. static scanning. Know that detection is a
  *separate layer* from prevention. Solidly **CKS** (the exam explicitly covers runtime security and
  Falco-style behavioral analytics).
- **Learn it:**
  - falco.io → Documentation → "Falco Rules" and "Default Rules".
  - falco.io → "The Falco Project" overview (explains eBPF vs kernel-module drivers).
  - ebpf.io → background reading on what eBPF actually is.

### Trivy Operator — continuous image + config vulnerability scanning

- **What it is / mental model:** Trivy is a popular open-source scanner (by Aqua Security); the **Trivy
  Operator** runs it *continuously inside the cluster*. Mental model: a building inspector who walks
  every room, checks each appliance against a recall list (the CVE — Common Vulnerabilities and Exposures
  — database), and files a report card per appliance. It answers "which of my running images have known
  vulnerabilities, and how bad?" plus "is this workload's *config* risky?" (e.g. runs as root, no
  resource limits).
- **How it works:** The operator watches workloads. For each new image it schedules a **scan Job** that
  pulls the image's package list and matches it against the CVE database, then writes the results back
  into the cluster as **Custom Resources** (CRs) — one `VulnerabilityReport` per workload container, plus
  `ConfigAuditReport` (misconfig), `ExposedSecretReport` (secrets baked into images), `RbacAssessmentReport`,
  and SBOM reports. Because they're just Kubernetes objects, you query them with `kubectl` and Prometheus
  can scrape the counts. No external SaaS, no agent in your app.
- **In THIS cluster:** `apps/security/trivy-operator.yaml` (chart 0.33.1, wave 5). It scans **all
  namespaces** (`targetNamespaces: ""`, line 20), throttled to **one scan job at a time**
  (`scanJobsConcurrentLimit: 1`, line 24) so it doesn't thrash this small cluster, and cluster-wide
  *compliance* cron is off (`clusterComplianceEnabled: false`, line 26) to save churn. The comment at
  lines 17-18 records real operational history: scanning was paused (replicas 0) during disk I/O
  contention with a co-tenant VM, then re-enabled after a hardware rebalance. Live:
  ```sh
  kubectl get crd | grep aquasecurity                       # the report CRDs exist
  kubectl get vulnerabilityreports -A                        # one row per scanned container
  # Find your worst images by critical-CVE count:
  kubectl get vulnerabilityreports -A \
    -o custom-columns='NS:.metadata.namespace,IMG:.report.artifact.repository,CRIT:.report.summary.criticalCount,HIGH:.report.summary.highCount' \
    | sort -k3 -nr | head
  kubectl get configauditreports -A                          # config-misconfig findings
  ```
  Look for non-zero `CRIT`/`HIGH` columns — those are your real, current CVEs.
- **Job relevance:** "How do you manage vulnerabilities in container images?" → shift-left scanning in CI
  *plus* continuous in-cluster scanning (Trivy Operator) to catch newly-disclosed CVEs in images you
  already deployed. Know CVE/CVSS severities and the difference between *image* scanning and *config*
  auditing. Maps to **CKS** (supply-chain security / image vulnerability scanning).
- **Learn it:**
  - aquasecurity.github.io/trivy-operator → "Vulnerability Scanning" and "Custom Resource Definitions".
  - aquasecurity.github.io/trivy → the standalone CLI docs (run `trivy image <img>` locally to feel it).

### kube-bench — auditing nodes against the CIS Kubernetes Benchmark

- **What it is / mental model:** The **CIS Kubernetes Benchmark** is a community-maintained checklist of
  hardening recommendations (file permissions on kube config files, API-server flags, kubelet settings,
  etc.). **kube-bench** is a tool (also by Aqua) that runs those checks and tells you PASS/WARN/FAIL per
  item. Mental model: a standardized home-inspection checklist — "is the smoke detector installed? are
  the locks rated? is the wiring to code?" — run against your *nodes*, not your apps.
- **How it works:** It's a one-shot Job, not a long-running operator. The pod needs host visibility
  (`hostPID`, host mounts of `/var/lib/kubelet` and `/etc/kubernetes`) so it can read the actual node
  config, then it prints a report with check IDs (e.g. `1.2.6`), a result, and remediation text. On a
  *managed* or *immutable* distro like Talos, many checks are N/A or already handled by the OS — Talos has
  no SSH and an immutable, minimal config — so the value here is partly educational (you learn what the CIS
  controls *are*) and partly drift-detection.
- **In THIS cluster:** `apps/security/kube-bench.yaml` deploys a raw manifest from `security/kube-bench/`
  rather than a chart. The actual Job is `security/kube-bench/job.yaml`: image
  `docker.io/aquasec/kube-bench:v0.14.0`, `args: ["run","--targets","node"]` (node-level checks only),
  `hostPID: true`, and read-only hostPath mounts (lines 14-37). A neat GitOps trick at lines 7-9:
  `argocd.argoproj.io/sync-options: Replace=true` plus a fixed Job name means *every Argo CD sync deletes
  and recreates the Job*, so the benchmark **reruns on each sync** (Jobs are immutable, so you can't just
  re-apply them). The namespace is `privileged` for the host access. Live:
  ```sh
  kubectl -n kube-bench get jobs                # STATUS Complete
  kubectl -n kube-bench logs job/kube-bench | less   # PASS/WARN/FAIL with check IDs + remediation
  kubectl -n kube-bench logs job/kube-bench | grep -E '^\[(PASS|WARN|FAIL)\]' | sort | uniq -c
  ```
  Read a few `[FAIL]`/`[WARN]` lines and their remediation text — that's the CIS benchmark teaching you
  what "hardened" means.
- **Job relevance:** "How do you know your cluster is hardened?" → CIS Benchmark + kube-bench (and the
  Trivy `compliance` reports for the same idea). Know that CIS publishes benchmarks for many systems, and
  that managed/immutable distros change which checks apply. **CKS** lists "use CIS benchmark to review
  the security configuration" as an explicit objective.
- **Learn it:**
  - github.com/aquasecurity/kube-bench → the README (how targets/versions work).
  - CIS website → search "CIS Kubernetes Benchmark" (the source checklist; free PDF after sign-up).

### HashiCorp Vault — the secrets engine (KV, auth methods, policies)

- **What it is / mental model:** Vault is a dedicated **secrets manager**: a hardened vault (literally)
  that stores secrets, controls who can read them, and can even *generate short-lived* credentials on
  demand. Mental model: a bank vault with a teller. Secrets go in the safe; nobody reads them directly —
  they present **identity** to the teller (an "auth method"), the teller checks their **policy** (what
  they're allowed), and hands back only the specific secret, for a limited time. The point: secrets live
  in *one* audited, access-controlled place, never scattered across YAML or Git.
- **How it works:** Four concepts. (1) **Seal/unseal** — Vault starts *sealed* (encrypted, unusable);
  you unseal it with key shares (Shamir's Secret Sharing). (2) **Secrets engines** — pluggable backends
  mounted at a path; the simplest is **KV** (key-value); others can dynamically mint database creds, PKI
  certs, cloud IAM tokens, etc. (3) **Auth methods** — how a client proves identity: token, AppRole, and
  crucially **Kubernetes auth** (a pod presents its ServiceAccount JWT, Vault verifies it with the API
  server). (4) **Policies** — HCL documents granting `read`/`list`/etc. on specific paths, attached to an
  auth role. Identity + policy = least-privilege access to exactly the right secret.
- **In THIS cluster:** `apps/security/vault.yaml` (chart 0.33.0, wave 5) runs Vault **standalone** (not
  HA) with a 2Gi Longhorn volume (lines 17-25), UI enabled (line 32), and the agent **injector disabled**
  because ESO does the pulling instead (line 30). Vault ships sealed and uninitialized *on purpose* — the
  bootstrap is a documented **manual** one-time step so the root token/unseal key never touch Git. The
  script `security/vault/seed-vault.sh` automates it (and `security/vault/manifests/README.md` is the
  hand-runnable version). It: inits with 1 key share (homelab tradeoff, line 13), unseals, enables a
  **kv-v2** engine at path `kubeshowcase` (line 24), writes the secret
  `kubeshowcase/api  message="Hello from Vault via External Secrets Operator"` (line 25), enables
  **kubernetes** auth (line 27), writes an `eso-reader` **policy** granting read on
  `kubeshowcase/data/*` (lines 29-32), and binds it to a **role** that only the `external-secrets`
  ServiceAccount in the `external-secrets` namespace can assume (lines 33-36). The Vault UI is reachable
  at `http://vault.192.168.1.27.nip.io` (see `security/vault/manifests/httproute.yaml`). Live (read-only):
  ```sh
  kubectl -n vault get pods                              # vault-0  1/1 Running (unsealed)
  kubectl -n vault exec vault-0 -- vault status          # Sealed: false, Initialized: true
  # Read the secret ESO consumes (needs the root token, kept in your password manager):
  # kubectl -n vault exec -it vault-0 -- sh -c 'VAULT_TOKEN=<root> vault kv get kubeshowcase/api'
  ```
- **Job relevance:** "How do you manage secrets?" → name Vault as the gold-standard secrets platform;
  explain seal/unseal, the KV engine, *dynamic secrets* (its killer feature — short-lived DB creds that
  auto-expire), and Kubernetes auth. Contrast with cloud secrets managers (AWS Secrets Manager, etc.).
  Vault knowledge is highly valued in platform/SRE roles even though it's not a Kubernetes-cert topic
  per se (touches **CKS** secrets handling).
- **Learn it:**
  - developer.hashicorp.com/vault → "Get Started" tutorials (seal/unseal, KV v2, policies).
  - developer.hashicorp.com/vault → search "Kubernetes auth method".
  - developer.hashicorp.com/vault → "Secrets Engines" overview (skim dynamic secrets to see the magic).

### External Secrets Operator — syncing Vault secrets into native Kubernetes Secrets

- **What it is / mental model:** Pods consume secrets as native Kubernetes `Secret` objects (env vars or
  mounted files). Vault stores secrets *somewhere else*. The **External Secrets Operator** (ESO) is the
  bridge: it logs into Vault on the cluster's behalf, fetches the value, and **continuously syncs** it
  into a normal `Secret`. Mental model: a courier who, on a schedule, walks to the bank vault, withdraws
  exactly the documents you're authorized for, and drops a fresh copy in your office mailbox — so your app
  just reads its mailbox (a plain Secret) and never needs the vault's combination.
- **How it works:** Two CRDs. A **SecretStore** / **ClusterSecretStore** describes *where* and *how* to
  authenticate (provider = vault, server URL, auth = kubernetes role). An **ExternalSecret** describes
  *what* to fetch and *where to put it*: it references a store, lists `data` mappings
  (remote key/property → local secret key), and ESO creates/owns a target `Secret`, refreshing it on
  `refreshInterval`. If the upstream value rotates in Vault, the Kubernetes Secret updates automatically —
  no commit, no redeploy. This is the "secrets owned by a platform, rotated centrally" model, in contrast
  to SOPS (secrets encrypted *in Git*, rotated by PR).
- **In THIS cluster:** `apps/security/external-secrets.yaml` installs the operator (chart 2.6.0, wave 5);
  `apps/security/eso-config.yaml` deploys the store config on **wave 6** (after both ESO and Vault exist).
  The store is `security/eso/vault-store.yaml` — a **ClusterSecretStore** named `vault-kv` pointing at
  `http://vault.vault.svc:8200`, path `kubeshowcase`, version `v2`, authenticating via the **kubernetes**
  auth method with role `eso-reader` and the `external-secrets` ServiceAccount (this is the *other half*
  of the role the seed script created in Vault). Note `SkipDryRunOnMissingResource=true` (line 8) so Argo
  CD doesn't fail its dry-run before the CRD exists. The consumer is
  `workloads/kubeshowcase/external-secret.yaml`: an `ExternalSecret` named `ks-vault-secret` that pulls
  `kubeshowcase/api` property `message` into a Secret key `VAULT_MESSAGE`, refreshed every `1m`. Its
  header comment (lines 1-4) is a great interview soundbite: SOPS vs ESO and *when to use which*. Live —
  watch the whole chain work end to end:
  ```sh
  kubectl get clustersecretstore vault-kv               # READY=True, STATUS=Valid
  kubectl -n kubeshowcase get externalsecret            # ks-vault-secret  STATUS=SecretSynced  READY=True
  kubectl -n kubeshowcase get secret ks-vault-secret -o jsonpath='{.data.VAULT_MESSAGE}' | base64 -d; echo
  #   -> "Hello from Vault via External Secrets Operator"   (the value that lives in Vault)
  ```
- **Job relevance:** "How do you get secrets from <Vault/cloud manager> into Kubernetes without committing
  them?" → External Secrets Operator + a SecretStore/ExternalSecret, with refresh-driven rotation. Know
  the SOPS-vs-ESO tradeoff (in-Git encrypted vs runtime-synced) — this repo deliberately demonstrates both.
  **CKS** secrets management.
- **Learn it:**
  - external-secrets.io → "Introduction" and "API → ExternalSecret / ClusterSecretStore".
  - external-secrets.io → "Provider → HashiCorp Vault" (the exact auth config you have here).

## Hands-on lab (on YOUR cluster)

First, in every shell:
```sh
cd /Users/ccampbell/dev/talos-test
export KUBECONFIG=$PWD/terraform/.kubeconfig
```

**1. Map the security posture (RBAC + PSS, read-only).**
```sh
# Which namespaces enforce which Pod Security level?
kubectl get ns -o custom-columns='NAME:.metadata.name,ENFORCE:.metadata.labels.pod-security\.kubernetes\.io/enforce'
# Probe the least-privilege ServiceAccount two ways:
kubectl auth can-i get configmaps -n kubeshowcase --as=system:serviceaccount:kubeshowcase:ks-api      # yes
kubectl auth can-i delete secrets  -n kubeshowcase --as=system:serviceaccount:kubeshowcase:ks-api      # no
```
*Success:* `kubeshowcase` shows `restricted`; the first `can-i` prints `yes`, the second `no`. You've just
proven RBAC is default-deny and additive.

**2. Watch Pod Security *block* something (safe, self-contained).** Try to run a privileged pod in the
restricted namespace:
```sh
kubectl -n kubeshowcase run pss-test --image=busybox --restart=Never \
  --overrides='{"spec":{"containers":[{"name":"c","image":"busybox","securityContext":{"privileged":true},"command":["sleep","60"]}]}}'
```
*Success:* the API server **rejects** it with a `violates PodSecurity "restricted"` error listing the
exact violations (privileged, runAsNonRoot, capabilities, seccomp). Nothing to clean up — the pod was
never created. This is preventive control working at admission time.

**3. See Kyverno auditing the whole cluster.**
```sh
kubectl get cpol                                          # all five policies, READY=True, action Audit
kubectl describe cpol require-non-root | sed -n '1,40p'   # read the actual rule + failureAction
# Which workloads currently FAIL a policy (in Audit mode, so nothing is blocked)?
kubectl get policyreport -A | awk 'NR==1 || $6>0'         # rows with FAIL count > 0
```
*Success:* you see the five policies Ready, `validationFailureAction: Audit`, and at least one
PolicyReport row with a non-zero FAIL (e.g. in `goldilocks`). That row is Kyverno's background scanner
flagging an existing object without blocking it.

**4. Trip Falco's "shell in a container" tripwire.** Falco's default ruleset alerts when an interactive
shell is spawned inside a container. Pick any running app pod and exec into it, then read Falco's log:
```sh
POD=$(kubectl -n kubeshowcase get pod -l app.kubernetes.io/part-of=kubeshowcase -o name 2>/dev/null | head -1)
[ -z "$POD" ] && POD=$(kubectl -n kubeshowcase get pod -o name | head -1)
kubectl -n kubeshowcase exec -it "$POD" -- sh -c 'id; echo tripwire' || true
# Now look for the alert on the node that pod runs on:
kubectl -n falco logs ds/falco -c falco --since=2m | grep -iE 'shell|spawn|terminal' | tail
```
*Success:* a JSON line mentioning a shell/terminal being spawned in a container appears in Falco's log.
You just generated and detected a (benign) runtime event — exactly how Falco surfaces real intrusions.

**5. Read your actual vulnerability and CIS reports.**
```sh
# Worst images by critical/high CVE count:
kubectl get vulnerabilityreports -A \
  -o custom-columns='NS:.metadata.namespace,IMG:.report.artifact.repository,TAG:.report.artifact.tag,CRIT:.report.summary.criticalCount,HIGH:.report.summary.highCount' \
  | sort -k4 -nr | head
# CIS node benchmark results:
kubectl -n kube-bench logs job/kube-bench | grep -E '^\[(PASS|WARN|FAIL)\]' | sort | uniq -c
```
*Success:* you get a ranked list of images with CVE counts, and a PASS/WARN/FAIL tally from kube-bench.
Pick one `[FAIL]` line and read its remediation text in the full log.

**6. Trace a secret from Vault to a pod (the full ESO chain).**
```sh
kubectl get clustersecretstore vault-kv                    # STATUS Valid, READY True
kubectl -n kubeshowcase get externalsecret ks-vault-secret # STATUS SecretSynced, READY True
kubectl -n kubeshowcase get secret ks-vault-secret -o jsonpath='{.data.VAULT_MESSAGE}' | base64 -d; echo
```
*Success:* the decoded value is `Hello from Vault via External Secrets Operator` — a string that lives
only in Vault (`kubeshowcase/api`), authenticated via the cluster's ServiceAccount, couriered into a
native Secret by ESO, refreshed every minute. *(Optional, reversible: change the value in Vault via the
UI at `http://vault.192.168.1.27.nip.io`, wait up to 1m, re-run the last line, and watch it update.)*

## Check yourself

1. **What are the 4 Cs, and what's the core principle?** Cloud, Cluster, Container, Code — nested layers;
   an inner layer is only as secure as the layer outside it (defense in depth).
2. **Name the three Pod Security Standards and what `restricted` demands.** privileged / baseline /
   restricted; restricted requires non-root, drop ALL capabilities, seccomp `RuntimeDefault`, no
   privilege escalation, no host namespaces/paths.
3. **What replaced PodSecurityPolicy, and how is it configured?** Pod Security Admission enforcing the
   Pod Security Standards, configured by **labeling namespaces** (`pod-security.kubernetes.io/enforce|audit|warn`).
4. **What's the one command to check whether an identity can perform an action, and how do you test a
   ServiceAccount?** `kubectl auth can-i <verb> <resource> --as=system:serviceaccount:<ns>:<name>`.
5. **Kyverno's three rule types, and the Audit-vs-Enforce difference?** validate / mutate / generate;
   `Audit` records a violation in a PolicyReport but admits the object, `Enforce` rejects it at admission.
6. **Why is this cluster's Kyverno webhook fail-open, and why is that acceptable here?** Flaky cross-node
   networking could make the webhook unreachable and block all pod creation; it's safe only because every
   policy is `Audit` (a fail-open *Enforce* webhook would be a security hole).
7. **Falco vs. Trivy vs. kube-bench — what does each watch?** Falco watches live syscalls (eBPF) for
   runtime behavior; Trivy scans image packages + configs for known CVEs/misconfig; kube-bench audits
   *node* config against the CIS Benchmark. (Detective: behavior vs. images vs. node hardening.)
8. **How does ESO authenticate to Vault here, and what does it produce?** The `external-secrets`
   ServiceAccount presents its token to Vault's Kubernetes auth method (role `eso-reader`); ESO fetches
   `kubeshowcase/api` and syncs it into the native Secret `ks-vault-secret`, refreshed every minute.
9. **SOPS vs. ESO/Vault — when use which?** SOPS = config-like secrets encrypted *in Git*, rotated via PR
   by repo reviewers; ESO/Vault = runtime credentials owned by a secrets platform, rotated centrally
   without any commit.

## Where this fits in the path

**Before:** be comfortable with core workload objects, namespaces, ServiceAccounts, and GitOps/Argo CD
(earlier modules) — Pod Security, RBAC, and admission control only make sense once you know what a pod
and a ServiceAccount *are*, and every tool here is delivered as an Argo CD `Application`. **After:**
networking-layer security (NetworkPolicies / Cilium L3-L7, default-deny — the `kubeshowcase` namespace
already runs one) and supply-chain/backup-and-DR modules; together they complete the **CKS** picture.
