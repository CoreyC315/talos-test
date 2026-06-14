# Spegel
> A peer-to-peer image cache on every node that lets nodes pull image layers from each other — faster pulls, and resilience when the upstream registry is down.

**What it is.** Normally each node pulls every image from the upstream registry. Spegel notices that *another node already has that layer* and pulls it from that neighbour over the local network instead. Analogy: instead of six roommates each driving to the store for the same milk, the first one buys it and the rest grab it from the fridge. It also keeps you running through a brief registry outage — if a peer has the layer, you're fine.

**How it works.** Spegel runs as a DaemonSet, talks to each node's **containerd** socket to learn which layers are on disk, advertises them to peers via a distributed hash table, and programs containerd's registry-mirror hosts directory so a pull tries peers first, then falls back to the real registry. The hard-won detail here: Spegel manages the *entire* containerd hosts dir, so the default "mirror everything" also intercepts the plain-HTTP [[in-cluster-registry|in-cluster registry]] (which it can't proxy) and pulls **fail**. The fix is to explicitly list registries to mirror — including the in-cluster one with an `http://` scheme so containerd writes a working HTTP fallback.

**In this cluster.**
- The `spegel` Application (Helm `spegel` 0.7.1) with the explicit `mirroredRegistries` list and `prependExisting: true`: `apps/platform/spegel.yaml`. The inline comments are a real debugging war story.
- Talos `registries.mirrors` point at the node-local hostPort `29999`.
- Live: `kubectl -n spegel get pods -o wide` (one Running pod per node)

**See also:** [[in-cluster-registry]] · [[talos-linux]] · [[kubelet]] · [[cilium]] · [[gitops]] &nbsp; **Deep dive:** [[08-release-ops]]
