#!/usr/bin/env bash
# Installs Argo CD + the SOPS age key + the root app-of-apps. After this, Git drives everything.
set -euo pipefail
cd "$(dirname "$0")/.."

ARGOCD_CHART_VERSION=9.5.21 # Argo CD v3.4.3 — see versions.lock.md
AGE_KEY_FILE="${SOPS_AGE_KEY_FILE:-$HOME/.config/sops/age/keys.txt}"

helm repo add argo https://argoproj.github.io/argo-helm --force-update >/dev/null

kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -

# The ONE secret that cannot live in Git: the SOPS age private key.
kubectl -n argocd create secret generic sops-age \
  --from-file=keys.txt="${AGE_KEY_FILE}" \
  --dry-run=client -o yaml | kubectl apply -f -

helm upgrade --install argocd argo/argo-cd \
  --version "${ARGOCD_CHART_VERSION}" \
  --namespace argocd \
  --values bootstrap/argocd/values.yaml \
  --wait --timeout 10m

kubectl apply -f bootstrap/root-app.yaml

echo "==> Argo CD admin password:"
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
