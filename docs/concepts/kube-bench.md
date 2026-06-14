# kube-bench
> A one-shot auditor that checks your nodes against the CIS Kubernetes Benchmark and reports PASS/WARN/FAIL per item.

**What it is.** The **CIS Kubernetes Benchmark** is a community checklist of hardening recommendations (file permissions on kube configs, API-server flags, kubelet settings). **kube-bench** (by Aqua) runs those checks and tells you PASS/WARN/FAIL per item. Mental model: a standardized home-inspection checklist — "is the smoke detector installed? are the locks rated? is the wiring to code?" — run against your *nodes*, not your apps.

**How it works.** It's a one-shot Job, not a long-running operator. The pod needs host visibility (`hostPID`, host mounts of `/var/lib/kubelet` and `/etc/kubernetes`) to read the real node config, then prints check IDs (e.g. `1.2.6`), a result, and remediation text. On an immutable distro like [[talos-linux]] (no SSH, minimal config) many checks are N/A or handled by the OS — so the value is partly educational and partly drift-detection.

**In this cluster.**
- `apps/security/kube-bench.yaml` deploys a raw manifest, `security/kube-bench/job.yaml` (image `aquasec/kube-bench:v0.14.0`, `args: ["run","--targets","node"]`, `hostPID: true`). A [[gitops]] trick — `Replace=true` + a fixed Job name — makes [[argo-cd]] delete/recreate the immutable Job so the benchmark **reruns on every sync**. Namespace is [[pod-security-standards|privileged]].
- Read results: `kubectl -n kube-bench logs job/kube-bench | grep -E '^\[(PASS|WARN|FAIL)\]' | sort | uniq -c`

**See also:** [[trivy]] · [[falco]] · [[talos-linux]] · [[pod-security-standards]] · [[argo-cd]] &nbsp; **Deep dive:** [[07-security-governance]]
