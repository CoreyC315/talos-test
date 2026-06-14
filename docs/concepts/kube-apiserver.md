# kube-apiserver
> The cluster's front door — the single component everything talks to, and the only one that touches etcd.

**What it is.** The kube-apiserver is the REST API server at the center of Kubernetes. *Everything* — `kubectl`, kubelets, controllers, the scheduler — communicates through it; it's the front desk that every request passes. Mental model: a receptionist who authenticates you, checks your request is valid, and is the only one allowed into the records room ([[etcd]]).

**How it works.** It receives API requests, runs them through authentication, authorization ([[rbac]]), and admission control, then persists or reads the result from [[etcd]] — it is the *only* component that talks to etcd directly. It's stateless, so you run one per control-plane node and put them behind a single address for high availability. Here that address is a Talos *VIP* (`192.168.1.19:6443`) for external clients, while in-cluster components reach it via [[kubeprism]] on `localhost:7445`.

**In this cluster.**
- Runs as a static pod on cp-1/2/3 (one each); the VIP and `certSANs: 192.168.1.19` come from `talos/patches/cluster.yaml` and `talos/patches/nodes/cp-1.yaml`. Your kubeconfig points at the VIP (`grep server: terraform/.kubeconfig`).
- See it live: `kubectl get pods -n kube-system -o wide | grep apiserver` — three mirror pods `kube-apiserver-cp-{1,2,3}`.

**See also:** [[etcd]] · [[kubeprism]] · [[kube-scheduler]] · [[kube-controller-manager]] · [[rbac]] · [[talos-linux]] &nbsp; **Deep dive:** [[01-foundations]]
