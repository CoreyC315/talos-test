#!/usr/bin/env bash
# Imperative bootstrap — the ONLY manual kubectl/helm steps in the whole platform.
# Everything here is later adopted by ArgoCD from this same repo (identical values files).
# Prereqs: talosctl bootstrap done, kubeconfig merged, nodes NotReady (CNI=none) — expected.
# (terraform/ runs these exact steps as part of `terraform apply` — see terraform/bootstrap.tf.)
set -euo pipefail
cd "$(dirname "$0")/.."

CILIUM_VERSION=1.19.4

# Gateway API CRDs + the TLSRoute/Cilium gotcha (single source of truth, also used by Terraform).
./bootstrap/00-gateway-api-prep.sh

echo "==> Cilium ${CILIUM_VERSION} (CNI + kube-proxy replacement + Hubble + Gateway API, MTU 1450)"
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
