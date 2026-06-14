# Falco
> The CNCF runtime-security tripwire — watches live kernel syscalls via eBPF and alerts on suspicious container behavior.

**What it is.** Everything preventive stops bad things *before* they run; Falco assumes something already got in and watches what containers actually *do* at runtime. Mental model: a security camera with motion rules inside every room — [[rbac]] and [[kyverno]] are the door locks, Falco is the alarm that fires when someone inside starts jimmying a window (a shell spawned in a container, a write to `/etc`, an unexpected outbound connection).

**How it works.** Falco runs a **DaemonSet** (one pod per node) and taps the kernel via [[ebpf]] — a safe, sandboxed way to run small programs inside the kernel to observe events. It hooks **syscalls** (open a file, exec a binary, connect a socket), enriches them with container/Kubernetes metadata, and matches them against a rules file; a match produces an alert. This cluster uses the **modern eBPF** driver (no kernel module — important on [[talos-linux]], where you can't `insmod`).

**In this cluster.**
- `apps/security/falco.yaml` (chart 9.1.0, wave 5): `modern_ebpf` driver, `json_output: true`, and **falcosidekick** fanning alerts to the cluster's Alertmanager so a Falco hit becomes a normal [[prometheus]]/alerting event. Namespace labeled [[pod-security-standards|privileged]] for host/eBPF access.
- Watch alerts: `kubectl -n falco logs ds/falco -c falco | grep -i '"priority"' | tail` (exec into any pod to trip the default "terminal shell in container" rule).

**See also:** [[ebpf]] · [[cilium]] · [[trivy]] · [[kube-bench]] · [[prometheus]] &nbsp; **Deep dive:** [[07-security-governance]]
