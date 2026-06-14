# Trivy
> Continuous in-cluster vulnerability and misconfiguration scanning — finds known CVEs and risky configs in your running workloads.

**What it is.** Trivy is a popular open-source scanner (by Aqua Security); the **Trivy Operator** runs it continuously inside the cluster. Mental model: a building inspector who walks every room, checks each appliance against a recall list (the CVE — Common Vulnerabilities and Exposures — database), and files a report card per appliance. It answers "which running images have known vulnerabilities, how bad?" plus "is this workload's config risky?" (runs as root, no resource limits).

**How it works.** The operator watches workloads; for each new image it schedules a **scan Job** that pulls the package list and matches it against the CVE database, then writes results back as **Custom Resources**: one `VulnerabilityReport` per container, plus `ConfigAuditReport`, `ExposedSecretReport`, `RbacAssessmentReport`, and SBOM reports. Because they're plain Kubernetes objects, you query them with `kubectl` and [[prometheus]] can scrape the counts — no external SaaS, no in-app agent.

**In this cluster.**
- `apps/security/trivy-operator.yaml` (chart 0.33.1, wave 5): scans **all namespaces**, throttled to **one scan job at a time** (`scanJobsConcurrentLimit: 1`) for this small box; cluster-compliance cron off. A comment records that scanning was paused (replicas 0) during disk I/O contention, then re-enabled.
- Find worst images: `kubectl get vulnerabilityreports -A -o custom-columns='NS:.metadata.namespace,IMG:.report.artifact.repository,CRIT:.report.summary.criticalCount,HIGH:.report.summary.highCount' | sort -k3 -nr | head`

**See also:** [[kyverno]] · [[falco]] · [[kube-bench]] · [[in-cluster-registry]] · [[prometheus]] &nbsp; **Deep dive:** [[07-security-governance]]
