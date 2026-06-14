# kube-scheduler
> The control-plane component that decides which node each new pod should run on.

**What it is.** The kube-scheduler watches for pods that have been created but not yet assigned to a node, and picks the best node for each. Mental model: an air-traffic controller assigning incoming planes to runways — it doesn't fly the plane (the [[kubelet]] does that), it just decides *where* it lands.

**How it works.** It runs a two-phase loop: *filtering* removes nodes that can't fit the pod (insufficient CPU/RAM per its [[requests-and-limits]], failing taints, unmet [[scheduling-constraints]] like node selectors/affinity/topology spread), then *scoring* ranks the survivors and binds the pod to the winner by writing the assignment back through the [[kube-apiserver]]. It only places pods — once bound, the kubelet on that node makes the pod real. Static pods (like the control plane itself) bypass the scheduler entirely.

**In this cluster.**
- Runs as a static pod on cp-1/2/3; topology-spread keys off the `topology.kubernetes.io/zone` label (the Proxmox host) set in `talos/patches/nodes/*.yaml`, so replicas spread across raiden/aether/nahida.
- See it live: `kubectl get pods -n kube-system | grep scheduler` (or `talosctl get staticpods`).

**See also:** [[kubelet]] · [[kube-apiserver]] · [[scheduling-constraints]] · [[requests-and-limits]] · [[kube-controller-manager]] &nbsp; **Deep dive:** [[01-foundations]]
