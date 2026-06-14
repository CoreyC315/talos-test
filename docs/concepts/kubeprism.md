# KubePrism
> A per-node internal load balancer Talos runs at localhost:7445 so in-cluster components reach the apiserver without depending on the VIP.

**What it is.** KubePrism is a Talos feature that gives every node a local endpoint (`localhost:7445`) which transparently load-balances across all healthy kube-apiservers. There are three answers to "which control plane do I talk to?": the *VIP* (`192.168.1.19`) is the external floating front door for humans and `kubectl`; KubePrism is the internal plumbing for pods. Mental model: a local switchboard on every node that always finds a working apiserver.

**How it works.** Talos runs a tiny TCP load balancer on each node listening on port 7445; it health-checks every [[kube-apiserver]] endpoint and forwards connections to a live one, spreading load across all three. Because it lives on localhost, in-cluster clients keep working even during a VIP failover. This matters most for [[cilium]], which runs kube-proxy-free: it's pointed at KubePrism as its `k8sServiceHost/Port` so the CNI can reach the apiserver before (and independently of) Kubernetes Services existing.

**In this cluster.**
- Enabled in `talos/patches/common.yaml` (`features.kubePrism.enabled: true`, `port: 7445`); it's the target Cilium uses for its kube-proxy replacement.
- See it live (`export TALOSCONFIG=...`): `talosctl -n 192.168.1.20 get kubeprismendpoints` — the apiserver endpoints it balances across.

**See also:** [[kube-apiserver]] · [[talos-linux]] · [[cilium]] · [[etcd]] · [[service]] &nbsp; **Deep dive:** [[01-foundations]]
