# Module 3: GitOps & Configuration — The Cluster Is the Repo

> Almost every modern platform team runs their clusters with GitOps: the desired state of the whole
> system lives in a Git repo, and a controller continuously makes the cluster match it. This is the
> single most marketable skill cluster in this module — "we use Argo CD / Flux" is on a huge fraction
> of platform-engineering and SRE job descriptions. After this module you'll be able to read any Argo
> CD `Application`, explain why it's green or red, trace how a Helm chart + your own overlays + an
> encrypted secret all get rendered into the cluster, and safely change something through Git and
> watch the controller reconcile it. You already built all of this in *this* repo — now you'll
> understand every moving part.

## The big picture

In Module 1 you learned how Talos turns three machines into a Kubernetes cluster, and in Module 2 how
`kubectl` and the API server let you talk to it. But notice something: in *this* repo, you almost
never run `kubectl apply` to install software. Instead, every piece of software — Cilium, Longhorn,
Prometheus, Vault, all 30-odd of them — is described by a small YAML file under `apps/`, and a
controller called **Argo CD** reads those files from GitHub and makes the cluster match them. Git is
the source of truth; the cluster is just a *projection* of Git. That's **GitOps**.

The tools in this module form a rendering pipeline. Git holds the desired state. **Argo CD** is the
reconciler that watches Git and the cluster and closes the gap. Most of what it installs is packaged
as **Helm** charts (templated bundles of Kubernetes YAML). For the bits Helm doesn't cover — your own
HTTPRoutes, backup schedules — you layer on **Kustomize** (patch/compose plain YAML, no templating).
And because some of that YAML contains passwords, **SOPS + age + KSOPS** let you commit *encrypted*
secrets to Git that only the cluster can decrypt.

```
                  GitHub repo (CoreyC315/talos-test)
                  apps/*.yaml  +  platform/.../manifests/  +  *.sops.yaml
                                   |
                                   v
   +------------------------------------------------------------------+
   |  Argo CD (runs IN the cluster, namespace: argocd)                |
   |                                                                  |
   |  repo-server  --renders-->  Helm charts  + Kustomize overlays    |
   |       |                         |              |                 |
   |       |                         |          KSOPS plugin          |
   |       |                         |          decrypts *.sops.yaml  |
   |       v                         v              v                 |
   |  application-controller: compares rendered manifests vs cluster, |
   |  applies the diff, reports Synced/Healthy                        |
   +------------------------------------------------------------------+
                                   |
                                   v
                       Live Kubernetes objects
```

The "app-of-apps" twist: one Argo CD `Application` named **root** points at the `apps/` directory and
creates *one Application per file it finds there*. So `git push` a new file into `apps/`, and a new
piece of software appears in the cluster. The cluster genuinely *is* the repo.

## Tools in this module

### GitOps philosophy — make the cluster a deterministic function of Git

- **What it is / mental model:** GitOps is an operating model with two rules: (1) the entire desired
  state of your system is declared in Git, and (2) an automated agent continuously reconciles the
  live system to match Git. Think of it like a **thermostat**. You don't manually toggle the furnace;
  you set the target temperature (Git), and the thermostat (Argo CD) keeps measuring the room and
  acting until reality matches the target. "Declarative" means you describe the *destination*, not
  the *driving directions* — you say "Longhorn 1.12.0 should exist," not "run these install steps."
- **How it works:** Four principles (from OpenGitOps): the system is **declarative**; desired state is
  **versioned and immutable** (Git history = an audit log of every change, with `git revert` as your
  rollback); changes are **pulled automatically** by an agent *inside* the cluster (not pushed in by a
  CI runner with cluster credentials — more secure); and the system is **continuously reconciled** (if
  someone hand-edits a live object, the agent notices the *drift* and corrects it). The payoff:
  reproducibility (rebuild the cluster from Git — this repo literally has a `docs/REBUILD.md`),
  auditability, and easy rollback.
- **In THIS cluster:** The whole repo *is* the practice of GitOps. The single entry point is
  `bootstrap/root-app.yaml` — after you bootstrap Argo CD once, "Git drives everything" (its own
  comment in `bootstrap/02-bootstrap-argocd.sh:1`). Compare the imperative bootstrap (a shell script
  that runs `helm` and `kubectl` by hand, lines 18-24) with everything *after* it, which is pure
  declarative YAML reconciled from Git.

  ```bash
  export KUBECONFIG=$PWD/terraform/.kubeconfig
  # Every running app is declared by a file in apps/ — count them:
  ls apps/**/*.yaml | wc -l
  kubectl get applications -n argocd
  ```
  Look for: the number of files roughly matches the number of Applications, and almost everything
  reads `Synced   Healthy`.
- **Job relevance:** Interviewers ask "what is GitOps and why is it better than `kubectl apply` in
  CI?" Good answers: audit trail + rollback via Git history; no cluster creds in CI (pull not push);
  self-healing against drift; reproducible clusters. Know the two reconcilers by name: **Argo CD** and
  **Flux**. Not a formal cert objective, but the *mindset* underpins CKA's "declarative config" theme.
- **Learn it:** OpenGitOps project site (`opengitops.dev`) — read "Principles v1.0.0." Argo CD docs
  (`argo-cd.readthedocs.io`) — intro "What Is Argo CD?". Search term: "GitOps push vs pull model."

### Argo CD — the controller that makes the cluster match the repo

- **What it is / mental model:** Argo CD is a Kubernetes controller (a program that runs *in* the
  cluster) whose entire job is reconciling `Application` resources. An **Application** is a custom
  resource that says "take the manifests at *this Git path / Helm chart*, render them, and apply them
  to *this namespace*." Mental model: Argo CD is a **CI/CD robot that lives inside the cluster and
  never sleeps** — it constantly diffs "what Git says" against "what's running" and presses Apply.
- **How it works — the pieces you must know:**
  - **Application:** the unit of deployment. `spec.source` (or `spec.sources` for multi-source) says
    *where the YAML comes from*; `spec.destination` says *where it goes* (cluster + namespace);
    `spec.syncPolicy` says *how* to keep them in sync.
  - **App-of-apps pattern:** an Application whose source is a *directory full of other Application
    manifests*. The `root` app (`bootstrap/root-app.yaml`) sets `path: apps` with
    `directory.recurse: true`, so it scans every subfolder of `apps/` and creates a child Application
    for each file. Adding software = adding one file + `git push`. This is how one bootstrap command
    fans out into ~30 apps.
  - **Sync waves:** the annotation `argocd.argoproj.io/sync-wave: "N"` orders deployment. Argo CD
    syncs all wave-0 things first, waits for them to be Healthy, then wave 1, and so on. This encodes
    dependencies: in this repo Cilium (the network) is wave **0**, storage/cert-manager are wave **2**,
    the Gateway is wave **3**, observability is wave **4**, security is **5**, operators **6**, and the
    demo app **7** (you saw the full ladder when you ran the survey). Wave 0 must come first because
    *nothing has a network until Cilium is up*.
  - **Sync status vs health status — two different questions.** **Sync** = "does the cluster match
    Git?" (`Synced` / `OutOfSync`). **Health** = "is the running thing actually working?"
    (`Healthy` / `Progressing` / `Degraded` / `Missing`). They're independent: a Deployment can be
    `Synced` (the YAML matches Git) but `Degraded` (its pods are crash-looping). You want both green.
  - **Automated sync / self-heal / prune** (all three set in `bootstrap/root-app.yaml:20-23`):
    `automated` = apply changes from Git without a human clicking Sync. `selfHeal: true` = if the live
    object drifts from Git (someone `kubectl edit`s it), revert it back to Git's version. `prune: true`
    = if you *delete* a manifest from Git, delete the corresponding live object too. Note the deliberate
    exception: `apps/platform/argocd.yaml` sets `prune: false` so Argo CD can never prune *itself* out
    of existence while managing itself.
- **In THIS cluster:**
  - Root/app-of-apps: `bootstrap/root-app.yaml` (`path: apps`, `recurse: true`, finalizer for clean
    cascading delete).
  - Sync waves: every file under `apps/` carries a `sync-wave` annotation (e.g.
    `apps/platform/longhorn.yaml:7` is `"2"`, `apps/observability/kube-prometheus-stack.yaml:7` is
    `"4"`).
  - Argo CD's own config: `bootstrap/argocd/values.yaml` (note `dex.enabled: false`, server runs
    insecure because TLS terminates at the Cilium Gateway, line 10).
  ```bash
  export KUBECONFIG=$PWD/terraform/.kubeconfig
  # Sync + health for everything, sorted; scan for anything not "Synced/Healthy":
  kubectl get applications -n argocd \
    -o custom-columns=NAME:.metadata.name,WAVE:'.metadata.annotations.argocd\.argoproj\.io/sync-wave',SYNC:.status.sync.status,HEALTH:.status.health.status

  # Open the web UI (then browse to https://localhost:8080, user: admin):
  kubectl -n argocd port-forward svc/argocd-server 8080:443
  # password:
  kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
  ```
  Look for: each app's wave number, and that the app-of-apps `root` is itself `Synced/Healthy` (it
  reports the *aggregate* health of its children via the custom Lua health check in
  `bootstrap/argocd/values.yaml:14-24`).
- **Job relevance:** Extremely high. Expect: "Explain sync vs health status" (the #1 Argo CD
  question), "What's the app-of-apps pattern?", "How do sync waves order dependencies?", "What does
  self-heal/prune do and when would you turn prune off?", "Auto-sync vs manual sync — pros/cons in
  prod?" Argo CD isn't on a CNCF cert exam directly, but GitOps tooling is core to most platform
  roles; the **Argo Project** has its own credential ("Certified Argo Project Associate", CAPA) if you
  want a paper credential.
- **Learn it:** `argo-cd.readthedocs.io` — read "Core Concepts," "Application Specification,"
  "Sync Options," and "Resource Health." Search the same docs for "App of Apps pattern" and
  "Sync Phases and Waves." The official **Argo CD** YouTube/CNCF intro talks are solid free video.

### Helm — the package manager for Kubernetes ("apt for clusters")

- **What it is / mental model:** A real piece of software (Prometheus, Longhorn) is dozens of
  Kubernetes objects — Deployments, Services, ConfigMaps, RBAC, CRDs. Writing all of those by hand for
  every install is miserable. **Helm** packages them into a templated bundle called a **chart**, with
  a single knobs-file called **values** that you override. Mental model: Helm is **`apt`/`brew` for
  Kubernetes** — `helm install prometheus` is like `apt install nginx`, and `values.yaml` is the
  config you tweak instead of editing the package internals.
- **How it works:** A chart is templates (Go-templated YAML) + a default `values.yaml` + metadata. At
  render time Helm substitutes your values into the templates and emits plain Kubernetes manifests
  (`helm template` shows exactly this). Charts live in **repositories** (HTTP index files like
  `https://charts.longhorn.io`, or OCI registries). You pin a **chart version**
  (`targetRevision`) for reproducibility. Crucially, **Argo CD renders Helm itself** — it runs
  `helm template`, then *Argo CD* (not Helm/Tiller) applies the result and tracks it. So you get
  Helm's packaging without Helm's release-state stored in-cluster.
- **In THIS cluster:** Most apps are a Helm source inside an Argo CD Application. Two idioms to know:
  - **Inline values via `valuesObject`** — values written directly in the Application YAML.
    `apps/platform/longhorn.yaml:11-42`: chart `longhorn` v`1.12.0` from `https://charts.longhorn.io`,
    with `valuesObject` setting replica counts, the NFS `backupTarget`, and
    `preUpgradeChecker.jobEnabled: false` (line 18 — a Helm-only hook that breaks under Argo CD).
    `apps/observability/kube-prometheus-stack.yaml:11-131` is a big one: chart v`86.2.2`, configuring
    Prometheus retention, Alertmanager routes, Grafana datasources, all as `valuesObject`.
  - **External values file via `$values`** — `apps/platform/argocd.yaml` uses a *multi-source*
    Application where one source is the chart and another is the Git repo tagged `ref: values`, then
    `valueFiles: [$values/bootstrap/argocd/values.yaml]` pulls the values from
    `bootstrap/argocd/values.yaml`. This is how Argo CD manages *itself* with the same values file the
    bootstrap script used.
  ```bash
  export KUBECONFIG=$PWD/terraform/.kubeconfig
  # See the chart + version Argo CD is tracking for an app:
  kubectl get application longhorn -n argocd -o jsonpath='{range .spec.sources[*]}{.chart}{" "}{.targetRevision}{" "}{.repoURL}{"\n"}{end}'

  # Render a chart locally to SEE what Helm produces (read-only):
  helm repo add longhorn https://charts.longhorn.io && helm repo update
  helm template longhorn longhorn/longhorn --version 1.12.0 | head -60
  ```
  Look for: the chart/version/repo printed for Longhorn matches `apps/platform/longhorn.yaml`; the
  `helm template` output is plain Deployments/Services — the "compiled" form of the chart.
- **Job relevance:** Universal. Expect: "What's a chart vs a release vs a repo?", "How do you override
  values?", "What does `helm template` do and why is it useful for debugging?", "Chart version vs app
  version?", "How does Argo CD use Helm (and why there's no Tiller anymore)?" Maps loosely to **CKAD**
  (packaging/deploying apps); Helm is explicitly allowed and commonly used in the exam environment.
- **Learn it:** `helm.sh/docs` — "Using Helm," "Charts," and "Values Files." Search terms:
  "helm template command," "helm chart values precedence." Try `helm create demo` locally to read a
  generated chart's structure.

### Kustomize — patch and compose plain YAML, no templating

- **What it is / mental model:** Helm templates YAML with `{{ }}` placeholders. **Kustomize** takes a
  different stance: keep your YAML *as plain valid YAML*, and apply *overlays* (patches) on top.
  Mental model: Helm is a **fill-in-the-blanks form**; Kustomize is **tracing paper** — you lay a
  patch over a base and only change the bits you mark. It's built into `kubectl` (`kubectl apply -k`).
- **How it works:** A `kustomization.yaml` lists `resources` (plain YAML files to include),
  `patches`/overlays (strategic-merge or JSON-6902 edits), and transformers (set a common `namespace`,
  name prefixes, labels, image tags). It can also run **generators** — including plugins. `kustomize
  build <dir>` emits the final combined YAML. In this repo Argo CD runs Kustomize for the
  *self-managed* portion of each app (the Git source pointing at a `manifests/` directory).
- **In THIS cluster:** Most apps are *Helm chart + your own Kustomize directory* in one Application —
  the multi-source pattern. Example: `apps/platform/longhorn.yaml` has source 1 = the Helm chart,
  source 2 = `path: platform/longhorn/manifests`. That directory's
  `platform/longhorn/manifests/kustomization.yaml` sets `namespace: longhorn-system`, lists three
  plain resources (`httproute.yaml`, `recurring-backup.yaml`, `backuptarget.yaml`), and a **generator**
  (`ksops-generator.yaml`) for the encrypted secret. Note the build options enabling plugins in
  `bootstrap/argocd/values.yaml:13` (`kustomize.buildOptions: --enable-alpha-plugins --enable-exec`) —
  required so KSOPS can run.
  ```bash
  # Build the same Kustomize overlay Argo CD builds (decryption may fail locally
  # without the age key — that's fine; you'll still see the namespace + resources):
  kustomize build platform/longhorn/manifests --enable-alpha-plugins --enable-exec 2>&1 | head -40
  # Or just inspect the kustomization:
  cat platform/longhorn/manifests/kustomization.yaml
  ```
  Look for: `namespace: longhorn-system` applied to every resource, and the three `resources` plus the
  `generators` entry.
- **Job relevance:** Common interview pairing: "Helm vs Kustomize — when would you use each?" (Helm for
  third-party packaged software; Kustomize for *your own* manifests and environment overlays without
  templating). "What's a base vs an overlay?" Kustomize is built into `kubectl`, so it's directly
  relevant to **CKAD** and **CKA** (`kubectl apply -k`, `kubectl kustomize`).
- **Learn it:** `kubectl.docs.kubernetes.io/references/kustomize` (the Kustomize reference) and
  `kubernetes.io` — search "Declarative Management of Kubernetes Objects Using Kustomize." Search
  terms: "kustomize bases and overlays," "kustomize strategic merge patch."

### SOPS + age + KSOPS — encrypted secrets that are safe to commit to Git

- **What it is / mental model:** GitOps wants *everything* in Git — but you must never commit a
  plaintext password. The fix: encrypt the secret *before* committing, so the file in Git is
  ciphertext, and only the cluster holds the key to decrypt it. Three tools cooperate:
  - **SOPS** (Secrets OPerationS, by Mozilla) — encrypts a YAML file's *values* while leaving the
    *keys/structure* readable, so diffs still make sense. Mental model: a **selective redactor** that
    blacks out only the secret values.
  - **age** — a tiny modern encryption tool that provides the actual public/private keypair SOPS uses.
    The **public key** (`age1...`) can be in Git and encrypts; the **private key** never leaves your
    machine and the cluster.
  - **KSOPS** — a *Kustomize plugin* that lets Kustomize (and therefore Argo CD's repo-server) call
    SOPS to decrypt `*.sops.yaml` files *at render time*, turning them into normal Kubernetes Secrets.
- **How it works:** `.sops.yaml` (repo root) holds **creation rules**: which files to encrypt, with
  which age recipient, and `encrypted_regex: ^(data|stringData)$` so only secret *values* are
  encrypted (so a Secret's `metadata`/`name` stay diffable). When you `sops -e`, each value becomes
  `ENC[AES256_GCM,...]` and a `sops:` block is appended with the age-encrypted data key and a **MAC**
  (tamper check). On the cluster side: Argo CD's repo-server has the **age private key** mounted from a
  Secret named `sops-age` (env `SOPS_AGE_KEY_FILE=/sops-age/keys.txt`,
  `bootstrap/argocd/values.yaml:55-71`), and a KSOPS binary installed via init-container
  (`values.yaml:72-83`). At sync time, Kustomize hits the `ksops` generator, KSOPS runs SOPS, decrypts
  using the mounted key, and emits a live Secret — the plaintext exists *only* in memory in the
  cluster, never in Git. The one secret that *can't* live in Git is the age private key itself; it's
  created imperatively at bootstrap (`bootstrap/02-bootstrap-argocd.sh:13-16`) and the values file
  comments "created imperatively at bootstrap; never in Git" (line 65).
- **In THIS cluster:**
  - Config: `.sops.yaml` — recipient `age1vth2pqfhwztat...skyp883`, two rules (a special whole-file
    rule for `talos/secrets.sops.yaml`, and the general `^(data|stringData)$` rule for every other
    `*.sops.yaml`).
  - An encrypted secret: `platform/longhorn/manifests/minio-credentials.sops.yaml` — note the keys
    (`AWS_ACCESS_KEY_ID`, etc.) are *readable* but the values are `ENC[AES256_GCM,...]`, plus the
    `sops:` metadata block with the age recipient and MAC.
  - The generator wiring: `platform/longhorn/manifests/ksops-generator.yaml` (`kind: ksops`, points at
    the `.sops.yaml` file) referenced under `generators:` in the kustomization.
  - There are 11 such encrypted files across the repo (Velero, Grafana admin, Loki/Tempo MinIO,
    CNPG, etc.).
  ```bash
  export KUBECONFIG=$PWD/terraform/.kubeconfig
  # The file in Git is ciphertext — confirm you cannot read the secret:
  grep -A2 stringData platform/longhorn/manifests/minio-credentials.sops.yaml

  # But the LIVE Secret in the cluster is the decrypted result KSOPS produced:
  kubectl get secret minio-credentials -n longhorn-system -o jsonpath='{.data.AWS_ENDPOINTS}' | base64 -d; echo

  # Prove decryption works (needs the age key; export it first if you have it locally):
  # export SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt
  sops -d platform/longhorn/manifests/minio-credentials.sops.yaml 2>&1 | head -12
  ```
  Look for: in Git you see only `ENC[...]`; in the cluster the Secret holds the real endpoint; `sops
  -d` (with the key) reveals plaintext — three views of the same secret.
- **Job relevance:** Secrets management is a hot interview topic. Expect: "How do you store secrets in
  a GitOps repo safely?" (encrypt-at-rest with SOPS, or external secret stores — this repo *also* runs
  External Secrets + Vault for the other approach). "Why is `encrypted_regex` set to data/stringData?"
  (keep manifests diffable). "Where does the decryption key live and why can't *it* be in Git?" This
  maps directly to **CKS** (the Security cert) domains on secrets and supply chain. Knowing the
  *trade-off* — SOPS/sealed-secrets (encrypted-in-Git) vs External Secrets/Vault (secret stays in an
  external store, only a *reference* in Git) — is a senior-level distinction.
- **Learn it:** SOPS GitHub `github.com/getsops/sops` (README — "Encrypting using age," "creation
  rules," `.sops.yaml`). age `github.com/FiloSottile/age` (README — keypairs). KSOPS
  `github.com/viaduct-ai/kustomize-sops` (README — Argo CD integration). Search terms: "sops age
  encrypted_regex," "argo cd ksops repo-server plugin."

## Hands-on lab (on YOUR cluster)

Run this first so every command works:

```bash
export KUBECONFIG=$PWD/terraform/.kubeconfig
```

**Lab 1 — Read the app-of-apps tree.** See how one `root` app spawns all the others.

```bash
kubectl get application root -n argocd -o jsonpath='{.spec.source.path}{"  recurse="}{.spec.source.directory.recurse}{"\n"}'
kubectl get applications -n argocd -o custom-columns=NAME:.metadata.name,WAVE:'.metadata.annotations.argocd\.argoproj\.io/sync-wave',SYNC:.status.sync.status,HEALTH:.status.health.status | sort -k2
```
Success: `root` reports `path: apps  recurse=true`, and you see ~30 child apps laddered by wave 0→7.
Confirm wave 0 is `cilium` (network first) and the highest wave is `kubeshowcase` (the demo app last).

**Lab 2 — Sync status vs health status, made concrete.** Pick the Longhorn app and read both fields,
then read *why* it's that state.

```bash
kubectl get application longhorn -n argocd -o jsonpath='SYNC={.status.sync.status}  HEALTH={.status.health.status}{"\n"}'
# Drill into the resources Argo CD tracks for this app:
kubectl get application longhorn -n argocd -o jsonpath='{range .status.resources[*]}{.kind}/{.name}  {.status}  {.health.status}{"\n"}{end}' | head -20
```
Success: top line is `SYNC=Synced  HEALTH=Healthy`. In the resource list you can see individual
objects and their health — articulate to yourself why sync ("matches Git") and health ("actually
running") are different questions.

**Lab 3 — Watch self-heal correct drift (safe + reversible).** Hand-edit a live object and watch Argo
CD revert it, because `selfHeal: true`. We'll bump a label, not anything functional.

```bash
# 1. Pick the longhorn-ui deployment (managed by Argo CD) and add a stray annotation:
kubectl -n longhorn-system annotate deployment longhorn-ui drift-test=hello --overwrite
# 2. Within ~1-3 min Argo CD notices OutOfSync and self-heals. Watch the app status:
kubectl get application longhorn -n argocd -w
#    (Ctrl-C once it returns to Synced)
# 3. Confirm the stray annotation is gone (self-heal removed it):
kubectl -n longhorn-system get deployment longhorn-ui -o jsonpath='{.metadata.annotations.drift-test}{"\n"}'
```
Success: the app flickers `OutOfSync` then returns to `Synced`, and the final command prints an empty
line — the drift was reverted automatically. This is GitOps continuous reconciliation in action.
(Fully reversible: you changed only a label, and Argo CD already undid it.)

**Lab 4 — Trace a Helm value from Git to the running cluster.** Longhorn's default replica count is
set as a Helm value in Git; verify the live setting matches.

```bash
# What Git says (the valuesObject in the Application):
grep -n "ReplicaCount" apps/platform/longhorn.yaml
# What the cluster runs (the Longhorn setting object reconciled from that value):
kubectl get setting.longhorn.io default-replica-count -n longhorn-system -o jsonpath='{.value}{"\n"}'
```
Success: Git shows `defaultReplicaCount: 2` (line ~24) and the live Longhorn setting reads
`{"v1":"2","v2":"2"}` — i.e. 2. You've traced one knob from `valuesObject` in Git → Helm render →
live `setting.longhorn.io` object.

**Lab 5 — See SOPS encryption from all three angles.** Ciphertext in Git, plaintext in the cluster.

```bash
# (a) In Git: only ENC[...] is visible — the secret is safe to commit:
grep -n "AWS_ACCESS_KEY_ID\|stringData" platform/longhorn/manifests/minio-credentials.sops.yaml
# (b) In the cluster: KSOPS decrypted it into a real Secret:
kubectl get secret minio-credentials -n longhorn-system -o jsonpath='{.data.AWS_ENDPOINTS}' | base64 -d; echo
# (c) The .sops.yaml policy that governs which files get encrypted and with whose key:
cat .sops.yaml
```
Success: (a) shows `ENC[AES256_GCM,...]` not a real key; (b) prints the real MinIO endpoint URL; (c)
shows the age recipient and `encrypted_regex: ^(data|stringData)$`. Same secret, three forms.

**Lab 6 — Inspect the KSOPS plumbing inside Argo CD.** Prove the decryption key lives only in the
cluster, mounted into the repo-server.

```bash
# The age private key Secret (the one thing NOT in Git):
kubectl get secret sops-age -n argocd
# The repo-server has it mounted + the SOPS_AGE_KEY_FILE env set:
kubectl -n argocd get deploy argocd-repo-server -o jsonpath='{range .spec.template.spec.containers[0].env[*]}{.name}={.value}{"\n"}{end}' | grep SOPS
kubectl -n argocd get deploy argocd-repo-server -o jsonpath='{.spec.template.spec.volumes[*].name}{"\n"}'
```
Success: the `sops-age` Secret exists, `SOPS_AGE_KEY_FILE=/sops-age/keys.txt` is set on the
repo-server, and a `sops-age` volume is mounted. Now you can explain the full decryption path end to
end.

## Check yourself

1. **Q:** In one sentence, what is GitOps? **A:** An operating model where Git holds the declared
   desired state and an in-cluster agent continuously reconciles the live system to match it.
2. **Q:** What's the difference between Argo CD's *sync* status and *health* status? **A:** Sync = does
   the cluster match Git (`Synced`/`OutOfSync`); health = is the running workload actually functioning
   (`Healthy`/`Degraded`/`Progressing`) — they're independent.
3. **Q:** What does the app-of-apps pattern do in this repo, and where is the root? **A:**
   `bootstrap/root-app.yaml` points at `apps/` with `recurse: true`, so Argo CD creates one child
   Application per manifest it finds — adding a file + `git push` installs new software.
4. **Q:** Why is Cilium sync-wave 0 while observability is wave 4? **A:** Sync waves order
   dependencies; nothing has a network until the CNI (Cilium) is up, so it must converge before
   anything that needs pod networking.
5. **Q:** What do `selfHeal` and `prune` do, and why does `apps/platform/argocd.yaml` set
   `prune: false`? **A:** `selfHeal` reverts live drift back to Git; `prune` deletes live objects whose
   manifests were removed from Git; Argo CD disables prune on itself so it can't delete itself while
   self-managing.
6. **Q:** Helm vs Kustomize — when do you reach for each? **A:** Helm to install templated third-party
   packages (charts + values); Kustomize to compose/patch your *own* plain YAML without templating
   (and it's built into `kubectl -k`).
7. **Q:** In a `*.sops.yaml` file, why are the YAML *keys* readable but the *values* encrypted? **A:**
   `encrypted_regex: ^(data|stringData)$` encrypts only secret values, keeping structure/metadata
   diffable in Git.
8. **Q:** Where does the SOPS decryption key live, and why can't it be committed to Git? **A:** It's
   the `sops-age` Secret mounted into Argo CD's repo-server (created imperatively at bootstrap); it's
   the private key that decrypts everything, so committing it would defeat the encryption.

## Where this fits in the path

**Before:** Module 1 (Talos/cluster foundation) and Module 2 (kubectl + the API/objects you'll see
referenced everywhere). **After:** with GitOps as the delivery mechanism, go into the *workloads it
delivers* — networking & ingress (Cilium, the Gateway API, HTTPRoutes you saw in the manifests),
then storage (Longhorn), then observability (the Prometheus/Grafana/Loki/Tempo stack this module's
examples configured).
