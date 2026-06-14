# 🗂 Concept Index

Atomic cards — each is *what a thing is, how it works, and where it lives in this cluster* in about a
screen. Click any `[[link]]`. New here? Begin at [[HOME]] or the
[[../learn/README#the-decoder-ring--what-even-is-that-in-one-line-each|one-line decoder ring]].
Deep versions live in the [[../learn/README|curriculum]]; live triage lives in [[../OPERATIONS|OPERATIONS]].

## 1 · Foundations — bare metal to a running cluster
[[proxmox|Proxmox]] · [[terraform|Terraform]] · [[talos-linux|Talos Linux]] · [[etcd]] ·
[[kube-apiserver]] · [[kube-scheduler]] · [[kube-controller-manager]] · [[kubelet]] · [[kubeprism|KubePrism]]
→ deep dive [[../learn/01-foundations|Module 1]]

## 2 · Networking — how pods talk, how the world reaches in
[[cni|CNI]] · [[cilium|Cilium]] · [[ebpf|eBPF]] · [[hubble|Hubble]] · [[service|Kubernetes Service]] ·
[[gateway-api|Gateway API]] · [[lb-ipam|LB-IPAM & L2]] · [[coredns|CoreDNS]] · [[mtu|MTU & VXLAN]]
→ deep dive [[../learn/02-networking|Module 2]]

## 3 · GitOps & configuration
[[gitops|GitOps]] · [[argo-cd|Argo CD]] · [[app-of-apps|App-of-Apps]] · [[sync-waves|Sync Waves]] ·
[[helm|Helm]] · [[kustomize|Kustomize]] · [[sops|SOPS / age / KSOPS]]
→ deep dive [[../learn/03-gitops|Module 3]]

## 4 · Storage & stateful data
[[persistent-volume|PersistentVolume & PVC]] · [[csi|CSI]] · [[longhorn|Longhorn]] ·
[[statefulset|StatefulSet]] · [[cloudnative-pg|CloudNativePG]] · [[minio|MinIO]] · [[redis|Redis]]
→ deep dive [[../learn/04-storage-data|Module 4]]

## 5 · Scaling, scheduling & resources
[[requests-and-limits|Requests & Limits]] · [[scheduling-constraints|Scheduling Constraints]] ·
[[metrics-server]] · [[hpa|Horizontal Pod Autoscaler]] · [[prometheus-adapter]] ·
[[vpa-goldilocks|VPA & Goldilocks]] · [[keda|KEDA]]
→ deep dive [[../learn/05-scaling-scheduling|Module 5]]

## 6 · Observability — metrics, logs & traces
[[observability-pillars|The Three Pillars]] · [[prometheus|Prometheus]] · [[promql|PromQL]] ·
[[grafana|Grafana]] · [[loki|Loki]] · [[tempo|Tempo]] · [[alloy|Grafana Alloy]] · [[node-exporter]]
→ deep dive [[../learn/06-observability|Module 6]]

## 7 · Security & governance
[[pod-security-standards|Pod Security Standards]] · [[rbac|RBAC]] · [[kyverno|Kyverno]] ·
[[falco|Falco]] · [[trivy|Trivy]] · [[kube-bench]] · [[vault|HashiCorp Vault]] ·
[[external-secrets|External Secrets Operator]]
→ deep dive [[../learn/07-security-governance|Module 7]]

## 8 · Release engineering & operations
[[argo-rollouts|Argo Rollouts]] · [[canary|Canary Deployment]] · [[in-cluster-registry|In-Cluster Registry]] ·
[[spegel|Spegel]] · [[cert-manager]] · [[reloader|Reloader]] · [[velero|Velero]]
→ deep dive [[../learn/08-release-ops|Module 8]]
