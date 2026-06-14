# Plan: Dual cluster (k0s ⇄ Talos) on a shared NAS data layer

**Status:** PLAN ONLY — nothing applied. Execute phase-by-phase later.
**Goal:** Run *either* the k0s (`homelab-devops`) or the Talos (`talos-test`) cluster on the same
Proxmox hosts, switch between them with one command, and have **all app data live on the Synology
NAS** so each cluster is disposable. Both clusters are already Terraformed — this plan adds the
**shared data layer** + a **switch button**, so you can run whichever you feel like learning on.

**Mental model:** the data is the pet; the clusters are cattle. State lives on the NAS (`192.168.1.210`);
a cluster is just compute you point at it. (See [[OPERATIONS]], [[longhorn]], [[persistent-volume]].)

---

## Guardrails (DO NOT)
- ❌ **Never run both clusters' apps against the same NFS config dir at the same time** → SQLite
  corruption. One cluster at a time. (RAM forces this anyway — you can't run both full clusters.)
- ❌ Don't delete the original Longhorn config volumes until the NFS copy is verified.
- ❌ Don't put irreplaceable data on Longhorn-only (cluster-bound). Config + media → NAS.
- ✅ Back up before the one-time config migration. ✅ Keep `reclaimPolicy: Retain` on NFS classes.

## Decisions (resolved — change here if you disagree)
- **Config storage:** NFS via `csi-driver-nfs`, **NFSv4.1** (the homelab already uses 4.1 for media →
  byte-range locking works → SQLite-safe). *Not* Longhorn-backup/restore (that's manual per switch).
- **NAS layout:** keep media on `/volume1/media`; put app **config** on a new share/dir
  **`/volume1/appconfig`** (separate so a wipe of one doesn't touch the other).
- **Apps stay per-cluster:** k0s keeps its Ingress-NGINX manifests; Talos uses Gateway API. Each
  cluster's Argo deploys its *own* copy of the apps. **Only the NAS data is shared** — don't try to
  share one manifest set across both.
- **Jellyfin is out of scope here** — its AMD-iGPU passthrough is a separate hard problem (see the
  migration notes). Plan for the *arr/automation apps; decide Jellyfin's GPU path on its own.

## Pre-flight checklist (verify before Phase 1)
- [ ] Both repos present: `~/dev/homelab-devops`, `~/dev/talos-test`
- [ ] NAS `192.168.1.210` reachable; you can administer Synology shares
- [ ] Talos cluster currently has only Longhorn StorageClasses (confirmed) — no NFS class yet
- [ ] Proxmox API token works (in `terraform/terraform.tfvars`) for the switch script
- [ ] You've decided the apps' `PUID:PGID` (the linuxserver images; homelab uses these) for NAS perms

---

## Phase 1 — Synology: create the shared config share  ·  *~20 min, no cluster changes*
**Goal:** an NFS export for app config, locked to the cluster subnet, owned by the apps' UID/GID.
1. [ ] Synology → Control Panel → Shared Folder → create **`appconfig`** (on `/volume1`).
2. [ ] Control Panel → File Services → NFS: ensure **NFSv4.1 enabled**.
3. [ ] On the share's NFS permissions: allow the LAN subnet (`192.168.1.0/24`), **Squash =
   "Map all users to admin"** *or* set maproot to the apps' UID/GID (e.g. `1000:1000`), enable
   "Allow connections from non-privileged ports".
4. **Done when:** from your Mac, `showmount -e 192.168.1.210` lists `/volume1/appconfig` (or a test
   mount succeeds).

## Phase 2 — Talos: add the NFS CSI driver + StorageClass  ·  *~30 min, the key new piece*
**Goal:** the Talos cluster can provision NFS-backed PVCs, with the same class name as k0s so PVC
specs are identical. **The one Talos gotcha: `kubeletDir` differs.**
- Source to copy from (homelab): `kubernetes/apps/nfs-driver/nfs-csi-driver.yaml` +
  `nfs-storage-class.yaml` (chart `csi-driver-nfs`, repo
  `https://raw.githubusercontent.com/kubernetes-csi/csi-driver-nfs/master/charts`).
1. [ ] New Argo app in talos-test: **`apps/platform/nfs-csi.yaml`** (sync-wave `2`, like longhorn),
   Helm `csi-driver-nfs`, with **`kubeletDir: /var/lib/kubelet`** ← *NOT* `/var/lib/k0s/kubelet`
   (Talos uses the standard path; this is the #1 thing that silently breaks a copy-paste).
2. [ ] Raw manifest **`platform/nfs-csi/storageclass.yaml`**: a StorageClass **`celestia-appconfig`**
   — `provisioner: nfs.csi.k8s.io`, `server: 192.168.1.210`, `share: /volume1/appconfig`,
   `reclaimPolicy: Retain`, `mountOptions: [nfsvers=4.1]`. (Dynamic provisioning → each PVC = a
   subdir under the share.) Optionally also mirror the `celestia-nfs` (media, `/volume1/media`) class
   so media PVCs match the homelab verbatim.
3. [ ] Wire it into the root app-of-apps (it's under `apps/`, auto-discovered) and let Argo sync.
4. **Done when:** `kubectl get sc` shows `celestia-appconfig`; a throwaway PVC on it goes `Bound` and
   a subdir appears under `/volume1/appconfig` on the NAS. Then delete the test PVC.

## Phase 3 — Repoint app config to NFS  ·  *~an afternoon, per-app, the bulk of the work*
**Goal:** each app's config PVC lives on the shared NFS class, so the data follows the switch.
Config PVCs to convert (from `longhorn` → the NFS class): `sonarr-config-pvc`, `radarr-config-pvc`,
`prowlarr-config-pvc`, `seerr-config-pvc`, `qbittorrent-config-pvc`, `komga-config-pvc`,
`suwayomi-config-pvc`, `akasha-config-pvc` (+ AI: `ollama-models`, `open-webui-data`). Media PVCs
(`irminsul-records-celestia-pvc`, `suwayomi-manga-celestia-pvc`) are already NFS — leave them.

Per app (do one, verify, then the rest):
1. [ ] **One-time data copy** Longhorn → NFS (while the app is stopped): a tiny migration `Job` that
   mounts the old Longhorn PVC + the new NFS path and `rsync -a`s the config across. (Pattern:
   homelab's `kubernetes/manual/synology-nfs/migration.yaml`.)
2. [ ] Edit the app's PVC `storageClassName` → the NFS class (in *each* cluster's manifests: k0s
   repo for the k0s copy, talos repo for the Talos copy).
3. **Done when:** the app starts, its settings/history persist across a pod delete, and the data is
   visible under `/volume1/appconfig/<pvc-subdir>` on the NAS.
> Start with **1–2 apps** (e.g. Sonarr + Prowlarr) to prove the pattern before doing all of them.

## Phase 4 — The switch button  ·  *~30 min, easy*
**Goal:** one command to swap which cluster is running (they can't both run full — RAM).
1. [ ] Create `~/dev/homelab-switch/Makefile` (or a `switch.sh`) using the Proxmox API token:
   - `make talos` → graceful-shutdown k0s VMs (`201,211,212,213`) → start Talos VMs (`220-225`).
   - `make k0s`   → graceful-shutdown Talos VMs (`220-225`) → start k0s VMs (`201,211,212,213`).
   - `make status` → print which VM set is running.
   - Reuse the stop/start pattern from this session (Proxmox `…/status/shutdown` + `…/status/start`).
2. [ ] Document the **two switch modes:** *toggle* (stop/start existing VMs — fast, keeps clusters
   intact) vs *rebuild* (`terraform destroy`/`apply` — clean, ~15-20 min, fresh PKI; good for the
   Talos side per [[REBUILD]]).
3. **Done when:** `make talos` leaves only Talos VMs running (verify in Proxmox / `kubectl get nodes`).

## Phase 5 — Prove the round-trip  ·  *~15 min, the payoff*
1. [ ] Boot **k0s**, in Sonarr add a recognizable item / change a setting.
2. [ ] `make talos` (k0s down, Talos up); open Sonarr on the Talos cluster.
3. **Done when:** the Talos Sonarr shows the *same* state — because its config PVC mounts the same
   `/volume1/appconfig` subdir. That's "switch with ease, data follows." 🎉

---

## Effort summary & minimum-viable path
| Phase | Effort | Core? |
|---|---|---|
| 1 NAS config share | ~20 min | ✅ core |
| 2 NFS CSI + class on Talos (`kubeletDir` fix!) | ~30 min | ✅ core |
| 3 Repoint app config → NFS (per app) | ~an afternoon | ✅ core (do incrementally) |
| 4 Switch `Makefile` | ~30 min | ✅ core |
| 5 Round-trip test | ~15 min | ✅ proof |

**MVP:** Phases 1, 2, 4 + *one* app in Phase 3 → you can already switch clusters and watch one app's
state follow. Add the rest of the apps at leisure. **Total core work ≈ a focused afternoon.**

## Open items to decide when executing
- Jellyfin GPU on Talos (out of scope here) — direct-play, separate box, or GPU passthrough.
- Whether to also share the **k0s** apps onto the same `appconfig` (so k0s ⇄ Talos share live state)
  or keep k0s on Longhorn (separate state, simpler). Shared state = the seamless version.
- Monitoring/Longhorn/cert-manager already exist on Talos — reconcile, don't duplicate (see the
  migration notes in this same `docs/plans/` area when you write the full app migration).

*Cross-refs: [[REBUILD]] (rebuild/destroy mechanics), [[OPERATIONS]] (triage + key locations),
[[csi]] · [[persistent-volume]] · [[longhorn]] (storage concepts).*
