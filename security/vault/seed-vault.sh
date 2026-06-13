#!/usr/bin/env bash
# One-time Vault init + ESO wiring (documented manual step — root token & unseal key
# go in YOUR password manager, never in Git). Run after the vault app is synced.
set -euo pipefail

NS=vault
echo "==> waiting for vault-0"
kubectl -n $NS wait pod/vault-0 --for=condition=PodScheduled --timeout=5m
sleep 5

if ! kubectl -n $NS exec vault-0 -- vault status 2>/dev/null | grep -q "Initialized.*true"; then
  echo "==> initializing (1 share / threshold 1 — homelab)"
  kubectl -n $NS exec vault-0 -- vault operator init -key-shares=1 -key-threshold=1 -format=json > /tmp/vault-init.json
  echo "!!! SAVE /tmp/vault-init.json CONTENTS IN A PASSWORD MANAGER, THEN DELETE THE FILE !!!"
fi
UNSEAL=$(jq -r '.unseal_keys_b64[0]' /tmp/vault-init.json)
ROOT=$(jq -r '.root_token' /tmp/vault-init.json)

kubectl -n $NS exec vault-0 -- vault operator unseal "$UNSEAL" >/dev/null
echo "==> unsealed"

kexec() { kubectl -n $NS exec -i vault-0 -- env VAULT_TOKEN="$ROOT" "$@"; }

kexec vault secrets enable -path=kubeshowcase kv-v2 2>/dev/null || true
kexec vault kv put kubeshowcase/api message="Hello from Vault via External Secrets Operator"

kexec vault auth enable kubernetes 2>/dev/null || true
kexec sh -c 'vault write auth/kubernetes/config kubernetes_host="https://kubernetes.default.svc:443"'
kexec sh -c 'vault policy write eso-reader - <<POL
path "kubeshowcase/data/*" { capabilities = ["read"] }
path "kubeshowcase/metadata/*" { capabilities = ["read", "list"] }
POL'
kexec vault write auth/kubernetes/role/eso-reader \
  bound_service_account_names=external-secrets \
  bound_service_account_namespaces=external-secrets \
  policies=eso-reader ttl=1h
echo "==> ESO can now read kubeshowcase/* via role eso-reader"
