# In-Cluster Registry
> A self-hosted OCI registry running inside the cluster that stores the app's container images, so the homelab doesn't depend on an external registry.

**What it is.** A registry is just a web server that speaks the OCI distribution API (`/v2/...`) — a "warehouse for container images." Running one *inside* the cluster keeps the homelab self-contained (pushing to ghcr.io would need a PAT with `write:packages`). The build pipeline does `docker buildx build` → `crane push --insecure` (plain HTTP) and records each image **digest** (`sha256:...`, the immutable content hash) into a lockfile.

**How it works.** A single `registry:3.0.0` pod with two deliberate hardening choices. It's **pinned to worker-1** (a stable, un-congested host) and exposes a **`hostPort: 5000`** so pulls travel the physical LAN at `192.168.1.23:5000` — bypassing the [[cilium|Cilium]] pod overlay and [[lb-ipam|LB-IPAM]] indirection, which are slower and flakier under load. Storage is a plain **`hostPath`** dir, not [[longhorn|Longhorn]], because the registry is a rebuildable cache — no need for replicated storage fighting reattach races. Talos's `registries.mirrors` tells containerd to treat `192.168.1.23:5000` as plain HTTP, so manifests can reference it directly.

**In this cluster.**
- The registry Deployment (`hostPort: 5000`, `nodeSelector: worker-1`, `hostPath: /var/lib/ks-registry`): `platform/registry/registry.yaml`, wired by `apps/platform/registry.yaml`.
- App images reference it directly, e.g. `image: 192.168.1.23:5000/ks-api:1.0.0` in `workloads/kubeshowcase/api.yaml`; digests in `workloads/kubeshowcase/images.lock`.
- Live: `kubectl -n registry exec deploy/registry -- wget -qO- http://localhost:5000/v2/_catalog`

**See also:** [[spegel]] · [[talos-linux]] · [[cilium]] · [[longhorn]] · [[lb-ipam]] &nbsp; **Deep dive:** [[08-release-ops]]
