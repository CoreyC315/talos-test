# Pod Security Standards — namespace exceptions

Default posture: namespaces should run `restricted` (or at least `baseline`).
The following namespaces are explicitly labeled
`pod-security.kubernetes.io/enforce: privileged`, each for a concrete
technical reason:

| Namespace        | Why privileged                                                                 |
|------------------|--------------------------------------------------------------------------------|
| `longhorn-system`| hostPath mounts of `/var/lib/longhorn` + iSCSI (host devices, privileged engine/instance-manager pods) |
| `falco`          | eBPF probe needs host access: hostPID-ish visibility, `/proc`, BPF syscalls, host filesystem mounts |
| `spegel`         | Mounts the host containerd socket to mirror/serve images peer-to-peer          |
| `kube-system`    | CNI (Cilium) and other node-level components need host networking, BPF, and host mounts |
| `kube-bench`     | CIS node benchmark Job: `hostPID: true` + read-only hostPath mounts of `/var/lib/kubelet` and `/etc/kubernetes` |

## Workload namespaces

- `kubeshowcase` is labeled `pod-security.kubernetes.io/enforce: restricted` —
  application workloads must run non-root, drop all capabilities, use a
  seccomp profile, and must not use host namespaces or hostPath volumes.

Everything else (e.g. `vault`, `external-secrets`, `kyverno`, `trivy-system`,
`minio`, `monitoring`) runs without a privileged exception; keep it that way.
