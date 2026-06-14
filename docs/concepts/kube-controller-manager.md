# kube-controller-manager
> The control-plane process that runs dozens of control loops, each driving actual state toward desired state.

**What it is.** The kube-controller-manager bundles most of Kubernetes' built-in *controllers* into one process. A controller is a loop that watches a kind of object and works to make reality match what was declared. Mental model: a building's facilities team, each member endlessly checking "is X the way it should be?" and fixing it if not — node controller, deployment controller, job controller, endpoint controller, and many more.

**How it works.** Each controller follows the same *reconcile* pattern: observe current state via the [[kube-apiserver]], compare to the desired state stored in [[etcd]], and take corrective action (create/delete/update objects) — then repeat forever. For example, the deployment controller notices a Deployment wants 3 replicas but only 2 Pods exist and creates one more. This level-triggered, declarative loop is the core engine that makes Kubernetes self-healing. It never talks to etcd directly — only through the apiserver.

**In this cluster.**
- Runs as a static pod on cp-1/2/3 (managed by Talos, visible in `talosctl get staticpods`). The same reconcile pattern is what custom operators and [[argo-cd]] extend.
- See it live: `kubectl get pods -n kube-system | grep controller-manager` — `kube-controller-manager-cp-{1,2,3}`.

**See also:** [[kube-apiserver]] · [[etcd]] · [[kube-scheduler]] · [[argo-cd]] · [[cert-manager]] &nbsp; **Deep dive:** [[01-foundations]]
