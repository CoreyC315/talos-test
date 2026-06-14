# Module 1: Foundations — Bare Metal to a Running Cluster

> This module is the floor everything else stands on. By the end you'll understand — and be able to
> demonstrate on your own live cluster — how three physical machines become six virtual machines,
> how those VMs get an operating system *declaratively* (no SSH, no `apt install`, no hand-editing),
> and how Kubernetes' "brain" (the control plane) and "muscles" (the data plane) are actually wired
> together. Interviewers for platform/SRE/DevOps roles assume you can answer "what happens between
> power-on and `kubectl get nodes`." After this module, you can — with real commands you ran yourself.

## The big picture

A Kubernetes cluster doesn't appear from nothing. There's a stack of layers, each one creating the
surface the next one runs on:

```
  ┌─────────────────────────────────────────────────────────────┐
  │  Kubernetes (pods, services…)   ← Modules 2+ build on top    │
  ├─────────────────────────────────────────────────────────────┤
  │  Talos Linux  — an OS that exists ONLY to run Kubernetes     │  ← this module
  │   control plane: etcd · apiserver · scheduler · ctrl-mgr     │
  │   data plane:    kubelet · containerd                        │
  ├─────────────────────────────────────────────────────────────┤
  │  6 VMs  (cp-1..3, worker-1..3)                               │  ← this module
  ├─────────────────────────────────────────────────────────────┤
  │  Proxmox  — the hypervisor on 3 physical hosts               │  ← this module
  │   raiden (16G) · aether (27G) · nahida (31G)                 │
  ├─────────────────────────────────────────────────────────────┤
  │  Bare metal — 3× Intel i7-4770 boxes                         │
  └─────────────────────────────────────────────────────────────┘

  Terraform is the *robot* that builds the two middle layers in one command
  (it talks to Proxmox to make VMs, then talks to Talos to configure them).
```

The whole idea of this module is **declarative infrastructure**: you describe the *end state you
want* in files committed to Git (this repo), and tools converge reality to match — instead of
clicking around a web UI or SSH-ing into boxes and running commands by hand (which nobody can
reproduce or review later). Proxmox is the hypervisor, Terraform is the builder, and Talos is an OS
designed from scratch to be configured by API rather than by a human with a shell.

## Tools in this module

### Proxmox — turning a few physical boxes into many isolated machines

- **What it is / mental model:** Proxmox VE (Virtual Environment) is a **hypervisor** — software that
  lets one physical computer pretend to be several independent computers (virtual machines, or VMs).
  Think of a physical server as an apartment *building* and each VM as a separate *apartment*: each
  has its own walls (isolated CPU/RAM/disk), its own front door, and tenants who can't see each
  other, even though they share the building's foundation. Proxmox is free and open-source, built on
  the same Linux KVM/QEMU virtualization tech the big clouds use under the hood. In this repo it
  plays the role AWS/GCP would play in a cloud setup: it's the thing that hands you machines.
- **How it works:** Proxmox runs directly on the bare-metal host (it *is* the host OS). It exposes a
  web UI on port 8006 and, crucially for us, a **REST API** on that same port. Every VM has a numeric
  `vmid`, a host it lives on, virtual CPUs, RAM, virtual disks, and virtual network cards bridged onto
  the LAN. You can create VMs by clicking, by the `qm` command-line tool, or — as we do — by having
  Terraform call the API. Here there are **3 physical hosts** named `raiden`, `aether`, and `nahida`,
  and the 6 cluster VMs are spread across them so that losing any one physical box can't take out the
  cluster.
- **In THIS cluster:**
  - The host names, VM IDs, and which physical box each VM lands on are declared in
    `terraform/locals.tf` (lines 18–25) — e.g. `cp-1 = { vmid = 220, host = "raiden", ... }`.
  - The VM *shape* (CPU type, BIOS, disk, network bridge, CD-ROM/ISO) is in `terraform/vms.tf`.
  - The Proxmox API endpoint and credentials are wired in `terraform/providers.tf` (lines 1–11):
    `endpoint = https://192.168.1.100:8006/`.
  - **See it live:** the cluster VMs report their identity back through Kubernetes node labels. Run
    `kubectl get nodes -L topology.kubernetes.io/zone` — the `ZONE` column shows the Proxmox host
    each node runs on (`raiden`/`aether`/`nahida`). Confirm the *one-CP-one-worker-per-host* balance:
    no host appears twice in the control-plane rows.
- **Job relevance:** You won't be quizzed on Proxmox specifically (most shops run cloud or VMware/
  OpenStack), but the *concept* is universal: interviewers ask "what's the difference between a VM
  and a container?" (a VM virtualizes hardware and runs a full kernel; a container shares the host
  kernel and isolates processes). Knowing the hypervisor layer also explains why "node failure" and
  "host failure" are different blast radii — a favorite reliability discussion. Not on any cert
  directly, but it's the substrate the CKA assumes exists.
- **Learn it:**
  - Official: **pve.proxmox.com** → "Proxmox VE Administration Guide," sections *Qemu/KVM Virtual
    Machines* and *Cluster Manager*.
  - Concept refresher: search "KVM QEMU hypervisor type 1 vs type 2" for how virtualization works.
  - Free hands-on: the official Proxmox YouTube channel's "Getting Started" videos.

### Infrastructure-as-Code + Terraform — building machines from committed text, not clicks

- **What it is / mental model:** **Infrastructure-as-Code (IaC)** means your servers, networks, and
  VMs are defined in version-controlled text files instead of created by hand. **Terraform** is the
  most common IaC tool. Mental model: Terraform is a **general contractor** with a blueprint (your
  `.tf` files) and a *ledger of what it has already built* (the state file). You say "make reality
  match the blueprint"; it compares the blueprint to the ledger, figures out the minimum set of
  changes, and executes them. Re-running it when nothing changed does nothing — that property is
  called **idempotence**, and it's the whole point.
- **How it works:** Terraform has a small set of verbs you'll use constantly:
  - **Providers** are plugins that teach Terraform how to talk to a specific system. This repo uses
    four (`terraform/versions.tf`): `bpg/proxmox` (creates VMs), `siderolabs/talos` (the *official*
    Talos provider — generates machine config, applies it, bootstraps etcd, fetches kubeconfig), plus
    `helm` and `kubernetes` for the layer above.
  - **Resources** are the things you want to exist (`resource "proxmox_virtual_environment_vm" "talos"`
    in `vms.tf` is "a VM"). **Data sources** read information without creating anything.
  - **`terraform plan`** shows you the diff — what it *would* create/change/destroy — *before* doing
    it. This dry-run is the safety feature that makes IaC reviewable. **`terraform apply`** executes
    the plan. **`terraform destroy`** tears it all down.
  - **State** (`terraform.tfstate`) is Terraform's ledger mapping your config to real-world object
    IDs. It can contain secrets (here it holds the Talos PKI and kubeconfig), so it's `.gitignore`d
    and, in production, kept in a remote backend (S3/MinIO) with locking.
- **In THIS cluster:** the *entire* "bare metal → running cluster" path is one `terraform apply`.
  - `terraform/vms.tf` — the 6 VMs, created from a single `for_each = local.nodes` loop so all six
    share one definition.
  - `terraform/talos.tf` — the full Talos bootstrap as resources: `talos_machine_secrets` (the PKI),
    `talos_machine_configuration_apply` (push config to each node), `talos_machine_bootstrap`
    (start etcd on cp-1, lines 65–72), `talos_cluster_kubeconfig` (pull the kubeconfig).
  - `terraform/providers.tf` + `terraform/versions.tf` — provider wiring and version pins.
  - **The DRY trick worth noticing:** `talos.tf` lines 11–13 read the *same* hand-written patch files
    the manual path uses via `file(...)`, so the Terraform path and the manual path can never drift
    apart. That "single source of truth" instinct is exactly what platform-engineering interviewers
    want to see.
  - **See it live (read-only, safe):**
    ```bash
    cd terraform
    terraform plan        # against the LIVE cluster's adopted state — read-only, changes nothing
    ```
    On this repo's adopted state you should see "No changes" (or only a harmless `stop_on_destroy`
    flag diff, as `terraform/README.md` notes). `plan` *never* modifies anything — it's the safe way
    to explore. You can also inspect the ledger: `terraform state list` shows every managed object;
    `terraform state show 'proxmox_virtual_environment_vm.talos["cp-1"]'` shows cp-1's full record.
- **Job relevance:** IaC + Terraform is one of the **single most-asked** skill areas for DevOps/
  platform roles. Expect: "What is Terraform state and why does it matter?", "What's the difference
  between `plan` and `apply`?", "How do you handle secrets in state?", "What is idempotence?", "How
  do you import an existing resource Terraform didn't create?" (this repo literally has an
  `import.sh` for exactly that — adopting the hand-built cluster). There's no CNCF cert for Terraform,
  but HashiCorp's **Terraform Associate** is a well-recognized credential and maps directly to this.
- **Learn it:**
  - Official: **developer.hashicorp.com/terraform** → the "Get Started" tutorials and the *State*
    and *Providers* concept docs.
  - Provider docs: search the Terraform Registry for "bpg/proxmox" and "siderolabs/talos" to see the
    exact resources used here.
  - Cert prep: search "HashiCorp Terraform Associate study guide" (the official exam objectives page).

### Talos Linux — an immutable, API-only operating system that exists only to run Kubernetes

- **What it is / mental model:** Talos is a Linux distribution stripped down to the absolute minimum
  needed to run Kubernetes — and then *locked shut*. There is **no SSH, no shell, no package
  manager, no `/bin/bash`** to log into. You don't administer it like a pet server; you talk to it
  over a secure **gRPC API** with the `talosctl` tool. Mental model: a normal Linux box is a
  *workshop* full of tools you can rearrange (and accidentally break); Talos is a **sealed appliance**
  — like a microwave. You configure it by sending it a config document, and it makes itself match.
  The OS is **immutable**: the root filesystem is read-only, so config drift (the slow divergence of
  "what's actually installed" from "what we think is installed") and most malware persistence simply
  can't happen. To change anything, you change the config and re-apply — the same declarative idea as
  Terraform, one layer down.
- **How it works:**
  - **Machine config:** a single YAML document per node describing *everything* — disk to install on,
    network, the Kubernetes version, certificates, sysctls. You generate it (here, the Terraform
    `talos` provider does), then `talosctl apply-config` ships it to the node. The node reconfigures
    itself and, on first install, reboots into the configured state.
  - **Patches:** rather than one giant config, Talos lets you layer small YAML *patches* onto a
    generated base, so common settings live in one shared file. This repo splits them three ways:
    `talos/patches/common.yaml` (every node), `talos/patches/cluster.yaml` (control-plane-only), and a
    per-node patch for hostname/IP.
  - **Image Factory + schematic:** Talos ships as a minimal image, and you bolt on optional **system
    extensions** (kernel modules / userspace tools) by declaring them in a **schematic** — a small
    YAML you submit to Talos's hosted **Image Factory**, which builds you a custom ISO/installer and
    returns a content-addressed **schematic ID**. Same schematic in → same image out, forever. This
    cluster's schematic is `talos/schematic.yaml`; its ID is the long hash
    `7d1fa2e0…2a092`, and it adds four extensions: `iscsi-tools` + `util-linux-tools` (needed by the
    Longhorn storage system), `qemu-guest-agent` (so Proxmox/Terraform can read the VM's boot-time IP),
    and `intel-ucode` (CPU microcode for the i7-4770 hosts).
- **In THIS cluster:**
  - `talos/schematic.yaml` — the four extensions and the committed schematic ID + ISO/installer URLs.
  - `talos/patches/common.yaml` — install disk `/dev/sda`, the Image Factory installer image,
    KubePrism on port 7445, **LUKS2 disk encryption** keyed off node UUID, inotify sysctls for the
    logging stack, NTP/DNS, and the registry mirrors.
  - `talos/patches/cluster.yaml` — control-plane-only: `cni: none` and `proxy: disabled` (Cilium does
    both jobs, covered in a later module) plus the VIP in `certSANs`.
  - `talos/patches/nodes/*.yaml` — each node's hostname, static IP, and Proxmox-host zone label
    (`cp-1.yaml` also carries the VIP block; `worker-3.yaml` documents the `nahida→raiden` rebalance).
  - **See it live (read-only):** Talos's API exposes its whole state as queryable *resources*, like a
    mini-Kubernetes for the OS itself. With `export TALOSCONFIG=$PWD/talos/clusterconfig/talosconfig`:
    ```bash
    talosctl -n 192.168.1.20 version            # node + k8s version (no SSH — this is the gRPC API)
    talosctl -n 192.168.1.20 get extensions     # the 4 schematic extensions, installed
    talosctl -n 192.168.1.20 dmesg | tail        # yes, you can read kernel logs — but you can't `ssh` in
    ```
    Notice you got node internals *without a shell* — that's the whole Talos thesis.
- **Job relevance:** Talos is increasingly common at security-conscious and edge shops, and it's a
  *fantastic* interview story: "immutable infra," "no SSH / reduced attack surface," "declarative OS
  config," "config drift" — all buzzwords you can back with hands-on experience. It isn't on the CKA/
  CKAD/CKS exams (those are vendor-neutral and assume any conformant distro), but the security
  posture (read-only root, full-disk encryption, minimal attack surface) is squarely **CKS** territory
  conceptually.
- **Learn it:**
  - Official: **talos.dev** → "What is Talos," "Production Notes," and the *Configuration Reference*.
  - Image Factory: **factory.talos.dev** — paste this repo's schematic ID into the URL to see the
    exact extension set.
  - Concept: search "immutable infrastructure pets vs cattle" for the philosophy this embodies.

### Kubernetes architecture — control plane vs data plane, and how they connect

- **What it is / mental model:** A Kubernetes cluster is split into two roles. The **control plane**
  is the *brain*: it stores the desired state, makes scheduling decisions, and runs control loops
  that drive reality toward that state. The **data plane** (the worker nodes) is the *muscle*: it
  actually runs your containers. Analogy: the control plane is an *air-traffic control tower*
  (deciding which plane goes where, keeping the authoritative log); the data plane is the *runways
  and aircraft* (where things physically happen). In this cluster the brain runs on `cp-1/2/3` and
  the muscle runs on `worker-1/2/3`.
- **How it works — the control-plane components (all run on cp-1/2/3):**
  - **etcd** — a distributed key-value database; the cluster's *single source of truth*. Every object
    (`kubectl get` anything) is a row in etcd. It uses the **Raft** consensus algorithm and needs a
    **quorum** (a majority) to accept writes: with 3 members, you can lose 1 and keep working; lose 2
    and the cluster goes read-only. That's *why* there are exactly 3 control planes, one per Proxmox
    host. (This repo's README notes etcd is also memory-hungry — control-plane RAM was raised
    2.5G→8G after etcd thrashing took the cluster down; a great real-world etcd war story.)
  - **kube-apiserver** — the front door. *Everything* talks to the apiserver (kubectl, kubelets,
    controllers); it's the only component that talks to etcd. It validates requests, enforces auth,
    and is stateless, so you run one per control-plane node behind a single address (the VIP, below).
  - **kube-scheduler** — watches for pods with no node assigned and picks the best node for each
    (based on resources, affinity, taints).
  - **kube-controller-manager** — runs dozens of **control loops** (node controller, deployment
    controller, etc.), each continuously comparing desired vs actual state and nudging toward desired.
- **How it works — the data-plane components (run on every node):**
  - **kubelet** — the agent on each node. It takes pod specs assigned to its node and makes them real
    by telling the container runtime to start containers; it reports node/pod health back to the
    apiserver. It's the bridge between "Kubernetes wants this" and "this Linux box runs it."
  - **containerd** — the **container runtime**: the thing that actually pulls images and runs
    containers (via the CRI, Container Runtime Interface). Kubernetes itself doesn't run containers;
    it delegates to containerd. Here it's `containerd://2.2.4` (visible in `kubectl get nodes -o wide`).
- **Static pods — the chicken-and-egg trick:** How do the apiserver and etcd start, when normally a
  pod needs the apiserver to schedule it? Answer: **static pods**. The kubelet watches a local
  directory of pod manifests on disk and runs them *directly*, with no apiserver or scheduler
  involved. The control-plane components are static pods — that's how the brain boots itself. (You
  *see* them in `kubectl get pods -n kube-system` as e.g. `kube-apiserver-cp-1`; those are read-only
  "mirror pods" the kubelet creates so they're visible, but their truth lives on the node's disk, not
  etcd.) On Talos, the kubelet and these static pods are managed by Talos itself.
- **The control-plane VIP and KubePrism — two answers to "which control plane do I talk to?":**
  - **VIP (Virtual IP):** there are three apiservers, but clients want *one* address. Talos provides a
    built-in **VIP** — here `192.168.1.19` — a floating IP that's always held by exactly one healthy
    control-plane node; if that node dies, another grabs it. Your kubeconfig points at
    `https://192.168.1.19:6443` (verify: `grep server: terraform/.kubeconfig`). This is *external*
    high availability for clients like `kubectl`.
  - **KubePrism:** an *internal* load balancer Talos runs **on every node** at `localhost:7445`. In-
    cluster components (and crucially Cilium, which runs kube-proxy-free) reach the apiserver via
    KubePrism instead of the VIP, so they keep working even during a VIP failover and spread load
    across all apiservers. It's configured in `talos/patches/common.yaml` (lines 9–12, port 7445). The
    VIP is the front door for *humans/tools*; KubePrism is the internal plumbing for *pods*.

  ```
   kubectl ──► VIP 192.168.1.19:6443 ──► whichever CP is healthy ──┐
                                                                    ▼
   in-cluster pod ──► localhost:7445 (KubePrism, every node) ──► any apiserver
                                                                    │
            cp-1 ┌──────────────┐  cp-2 ┌──────────────┐  cp-3 ┌──────────────┐
                 │ apiserver    │       │ apiserver    │       │ apiserver    │
                 │ etcd ◄──────────Raft────────►etcd◄──────Raft────────►etcd  │
                 │ scheduler    │       │ scheduler    │       │ scheduler    │
                 │ ctrl-manager │       │ ctrl-manager │       │ ctrl-manager │
                 └──────────────┘       └──────────────┘       └──────────────┘
  ```

- **In THIS cluster:**
  - **See the split:** `kubectl get nodes` — `cp-1/2/3` show `ROLES=control-plane`, workers show
    `<none>`. All six are `Ready` running `v1.35.6` on `Talos (v1.13.4)`.
  - **See the static control-plane pods two ways:** from Kubernetes' view,
    `kubectl get pods -n kube-system -o wide | grep -E 'apiserver|etcd|scheduler|controller'`
    (three of each, one per CP). From Talos' view of the *real* on-disk static pods:
    `talosctl -n 192.168.1.20 get staticpods` (lists `kube-apiserver`, `kube-controller-manager`,
    `kube-scheduler` — note **etcd is not here**; Talos manages etcd as a first-class OS service, not
    a kubelet static pod).
  - **See etcd membership/quorum:** `talosctl -n 192.168.1.20 etcd members` — exactly 3 members,
    `LEARNER=false`.
- **Job relevance:** This is the **#1 most-tested Kubernetes topic, period.** CKA expects you to know
  every component, debug a broken control plane, back up and restore etcd, and explain quorum. Classic
  questions: "Walk me through what happens when you run `kubectl apply`." (kubectl→apiserver→etcd;
  scheduler assigns a node; kubelet on that node tells containerd to run it.) "Why an odd number of
  etcd members?" (quorum math — even numbers add no fault tolerance.) "What's a static pod and when do
  you use one?" Maps hardest to **CKA**, with control-plane security touching **CKS**.
- **Learn it:**
  - Official: **kubernetes.io/docs** → "Concepts → Cluster Architecture" and "Kubernetes Components"
    (the canonical component diagram).
  - etcd: **etcd.io** → "FAQ" and "Disaster recovery"; search "Raft consensus visualization" for an
    interactive explainer.
  - Cert prep: search "Kubernetes the Hard Way" (Kelsey Hightower) — builds every component by hand;
    the best way to truly internalize this.

## Hands-on lab (on YOUR cluster)

First, point your tools at the live cluster (run once per shell):

```bash
cd ~/dev/talos-test                 # or wherever this repo lives
export KUBECONFIG=$PWD/terraform/.kubeconfig
export TALOSCONFIG=$PWD/talos/clusterconfig/talosconfig
```

**Lab 1 — Map the layers (Proxmox host → VM → node).**
```bash
kubectl get nodes -o wide
kubectl get nodes -L topology.kubernetes.io/zone
```
*Success:* six `Ready` nodes; the `ZONE` column shows `raiden`/`aether`/`nahida`. Confirm each
Proxmox host hosts exactly one control plane and one worker — cross-check against
`terraform/locals.tf` lines 18–25. You've just traced the physical→virtual→logical mapping.

**Lab 2 — Prove there's no SSH, only an API (the Talos thesis).**
```bash
talosctl -n 192.168.1.20 version          # works: gRPC API
talosctl -n 192.168.1.20 get extensions   # the 4 schematic extensions from talos/schematic.yaml
ssh 192.168.1.20                           # EXPECT THIS TO FAIL — there is no SSH daemon
```
*Success:* the `talosctl` calls return data (version, and `iscsi-tools`/`util-linux-tools`/
`qemu-guest-agent`/`intel-ucode`); `ssh` hangs/refuses. You've experienced "API-only, immutable OS"
firsthand. (Ctrl-C the ssh attempt.)

**Lab 3 — Find the static control-plane pods from both sides.**
```bash
talosctl -n 192.168.1.20 get staticpods                          # Talos' view: on-disk static pods
kubectl get pods -n kube-system -o wide | grep -E 'apiserver|etcd|scheduler|controller'
```
*Success:* `talosctl` lists apiserver/scheduler/controller-manager (and *not* etcd — Talos runs etcd
as its own service). In `kubectl` you see one of each per CP node as `*-cp-1/2/3`. Ask yourself: why
do these exist *before* the scheduler that would normally place them? (Answer in Check-yourself.)

**Lab 4 — Watch etcd quorum, the reason there are three control planes.**
```bash
talosctl -n 192.168.1.20 etcd members
talosctl -n 192.168.1.20 service etcd status
```
*Success:* exactly 3 members, all `LEARNER=false`; etcd service `Running/Healthy`. With 3 members the
cluster tolerates losing **one**. Reason out loud: what happens to *writes* if two control-plane VMs
are down? (It goes read-only — no quorum.)

**Lab 5 — Locate the VIP and prove kubectl uses it.**
```bash
grep 'server:' terraform/.kubeconfig                       # https://192.168.1.19:6443  ← the VIP
talosctl -n 192.168.1.20,192.168.1.21,192.168.1.22 get addresses | grep 192.168.1.19
```
*Success:* the kubeconfig server is the VIP `.19`; exactly **one** control-plane node currently owns
the `192.168.1.19/32` address (today it's cp-1). That single floating IP is your highly-available
front door. *(Optional, reversible, advanced:* gracefully reboot the VIP holder with
`talosctl -n 192.168.1.20 reboot` and re-run the `get addresses` grep against the other two CPs —
the VIP moves and `kubectl get nodes` keeps working through the failover. Only do this if you're
comfortable; it's a real, brief control-plane reboot.)*

**Lab 6 — Read the desired state without changing anything (Terraform + patches).**
```bash
cd terraform && terraform plan          # read-only diff against the adopted live state
terraform state list | head             # the ledger of managed objects
cd .. && sed -n '1,20p' talos/patches/common.yaml   # KubePrism :7445, LUKS2, install disk
```
*Success:* `plan` reports no meaningful changes (proves config == reality); `state list` shows the
VMs/Talos resources; the patch file shows the exact KubePrism port and LUKS2 block you read about
above. You've connected "the files in Git" to "the cluster that's running."

## Check yourself

1. **Q:** What's the difference between a VM and a container, in one sentence?
   **A:** A VM virtualizes hardware and runs its own kernel; a container shares the host kernel and
   only isolates processes — so VMs are heavier but more isolated.
2. **Q:** What does `terraform plan` do that makes IaC safe, and why is *state* needed at all?
   **A:** `plan` shows the dry-run diff before any change; state is Terraform's ledger mapping config
   to real resource IDs so it knows what already exists and what to change.
3. **Q:** Name the four control-plane components and the one that is the single source of truth.
   **A:** kube-apiserver, kube-scheduler, kube-controller-manager, and **etcd** — etcd is the source
   of truth.
4. **Q:** Why does this cluster have exactly three control-plane nodes?
   **A:** etcd needs a majority (quorum) to accept writes; 3 members tolerate losing 1 — and one CP
   sits on each Proxmox host so no single host failure breaks quorum.
5. **Q:** What is a static pod and why must the control plane run as static pods?
   **A:** A pod the kubelet runs directly from an on-disk manifest with no apiserver/scheduler — which
   is the only way to start the apiserver/etcd themselves (the bootstrap chicken-and-egg).
6. **Q:** Difference between the control-plane VIP and KubePrism?
   **A:** The VIP (192.168.1.19) is one external floating IP for clients like kubectl; KubePrism is a
   per-node internal load balancer (localhost:7445) for in-cluster components reaching the apiserver.
7. **Q:** How do you administer a Talos node, and what *can't* you do that you could on Ubuntu?
   **A:** Only via the `talosctl` gRPC API with a declarative machine config — there's no SSH, shell,
   or package manager; you change the config and re-apply.
8. **Q:** What is the Image Factory schematic ID, and what property does it guarantee?
   **A:** A content hash of your chosen system extensions (here adding iscsi-tools, util-linux-tools,
   qemu-guest-agent, intel-ucode) — the same schematic always builds the identical image.

## Where this fits in the path

**Before this:** comfort with the Linux command line, `git`, and the idea of a container/image (Docker
basics). **After this:** the cluster is alive but its nodes are deliberately `NotReady`-then-`Ready`
only because a CNI was installed — next, learn the **networking layer (Cilium, Gateway API, the VIP's
data-plane partner)** and then **GitOps with Argo CD**, which is what actually fills this empty cluster
with everything else.
