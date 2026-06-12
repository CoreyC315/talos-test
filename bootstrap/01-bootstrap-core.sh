#!/usr/bin/env bash
# Imperative bootstrap — the ONLY manual kubectl/helm steps in the whole platform.
# Everything here is later adopted by ArgoCD from this same repo (identical values files).
# Prereqs: talosctl bootstrap done, kubeconfig merged, nodes NotReady (CNI=none) — expected.
set -euo pipefail
cd "$(dirname "$0")/.."

GATEWAY_API_VERSION=v1.5.1 # pinned — see versions.lock.md
CILIUM_VERSION=1.19.4

echo "==> Gateway API CRDs ${GATEWAY_API_VERSION} (standard channel) — must precede Cilium"
kubectl apply -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml"

echo "==> Cilium ${CILIUM_VERSION} (CNI + kube-proxy replacement + Hubble + Gateway API)"
helm repo add cilium https://helm.cilium.io --force-update >/dev/null
helm upgrade --install cilium cilium/cilium \
  --version "${CILIUM_VERSION}" \
  --namespace kube-system \
  --values platform/cilium/values.yaml \
  --wait --timeout 10m

kubectl apply -f platform/cilium/manifests/lb-ipam.yaml

echo "==> Waiting for nodes Ready"
kubectl wait --for=condition=Ready nodes --all --timeout=10m
kubectl get nodes -o wide
