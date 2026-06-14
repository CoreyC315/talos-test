# etcd
> The distributed key-value database that is the cluster's single source of truth — every Kubernetes object lives here.

**What it is.** etcd is a consistent, distributed key-value store. In Kubernetes it is *the* database: every object you can `kubectl get` is a row in etcd. Mental model: the cluster's authoritative ledger — nothing is "real" until it's written here, and the whole control plane exists to read from and reconcile against it.

**How it works.** etcd runs as a cluster of members using the *Raft* consensus algorithm, which elects a leader and requires a *quorum* (a strict majority) to accept any write. With 3 members you can lose 1 and keep serving writes; lose 2 and there's no majority, so the cluster goes read-only. That quorum math is exactly *why* this cluster has 3 control-plane nodes, one per Proxmox host. Only the [[kube-apiserver]] talks to etcd; everything else goes through the apiserver.

**In this cluster.**
- 3 members, one per control-plane VM (`192.168.1.20/21/22`), defined by the node inventory in `terraform/locals.tf`. On Talos, etcd is a first-class OS service — not a kubelet static pod — so it won't appear in `talosctl get staticpods`.
- See it live (`export TALOSCONFIG=...`): `talosctl -n 192.168.1.20 etcd members` — exactly 3 members, `LEARNER=false`.
- Gotcha: etcd is memory-hungry; CP RAM was raised after etcd thrashing took the cluster down — see [[OPERATIONS]].

**See also:** [[kube-apiserver]] · [[talos-linux]] · [[kube-controller-manager]] · [[velero]] · [[requests-and-limits]] &nbsp; **Deep dive:** [[01-foundations]]
