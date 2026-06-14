# kubelet
> The per-node agent that turns "Kubernetes wants this pod" into "this Linux box is actually running it."

**What it is.** The kubelet is the Kubernetes agent that runs on *every* node (control plane and worker). It's the bridge between the cluster's intent and the physical machine: it takes the pod specs assigned to its node and makes them real, then reports node and pod health back up. Mental model: the on-site foreman who receives the work orders for their site and gets the actual building done.

**How it works.** The kubelet watches the [[kube-apiserver]] for pods bound to its node, then tells the container runtime (here `containerd`, via the CRI) to pull images and start containers; it runs liveness/readiness probes and streams status back to the apiserver. It also watches a local on-disk directory of *static pod* manifests and runs those directly with no apiserver or scheduler involved — that's the bootstrap trick that starts the control plane itself. On Talos there's no SSH; the kubelet and its static pods are managed by Talos.

**In this cluster.**
- Kubelet tuning lives in `talos/patches/common.yaml` — e.g. an `extraMounts` bind of `/var/lib/longhorn` ([[longhorn]] needs it) and inotify sysctls for the logging stack.
- See it live: `kubectl get nodes -o wide` (runtime `containerd://...`); `talosctl -n 192.168.1.20 get staticpods`.

**See also:** [[kube-scheduler]] · [[kube-apiserver]] · [[talos-linux]] · [[longhorn]] · [[cni]] · [[kubeprism]] &nbsp; **Deep dive:** [[01-foundations]]
