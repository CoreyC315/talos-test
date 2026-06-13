#!/usr/bin/env bash
# Post-GitOps finish — the two steps Argo CD can't do itself, run once after the fleet converges.
# Makes a full rebuild exactly:  terraform apply  →  ./bootstrap/03-finish.sh
#   1. build + push the app images to the in-cluster registry (Argo CD deploys the registry;
#      the images come from app-src/ which only this workstation can build)
#   2. initialise/unseal Vault + wire ESO (one-time; root token goes to YOUR password manager)
# Idempotent and wait-driven. Safe to re-run.
set -euo pipefail
cd "$(dirname "$0")/.."
export KUBECONFIG="${KUBECONFIG:-$PWD/talos/clusterconfig/kubeconfig}"

echo "==> [1/3] Waiting for the in-cluster registry (Argo CD, wave 2)…"
for i in $(seq 1 60); do
  kubectl -n registry get deploy registry >/dev/null 2>&1 && \
    [ "$(kubectl -n registry get deploy registry -o jsonpath='{.status.readyReplicas}' 2>/dev/null)" = "1" ] && break
  sleep 10
done
echo "    registry ready."

echo "==> [2/3] Building + pushing app images…"
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  ./load-and-chaos/build-and-push.sh "${IMAGE_TAG:-1.0.0}"
  # nudge the app to pull the freshly-pushed images (Rollout + Deployments)
  kubectl -n kubeshowcase rollout restart deploy/ks-frontend deploy/ks-worker 2>/dev/null || true
  kubectl argo rollouts restart ks-api -n kubeshowcase 2>/dev/null || \
    kubectl -n kubeshowcase rollout restart rollout/ks-api 2>/dev/null || true
else
  echo "    ⚠ Docker not available — skipping image build. Run ./load-and-chaos/build-and-push.sh"
  echo "      on a machine with Docker, then restart the kubeshowcase workloads."
fi

echo "==> [3/3] Vault init/unseal + ESO wiring…"
if kubectl -n vault get pod vault-0 >/dev/null 2>&1; then
  if kubectl -n vault exec vault-0 -- vault status 2>/dev/null | grep -q 'Initialized.*true'; then
    echo "    Vault already initialised — skipping (re-run security/vault/seed-vault.sh to reconfigure)."
  else
    ./security/vault/seed-vault.sh
  fi
else
  echo "    ⚠ vault-0 not present yet — re-run this script once the security tier is up."
fi

cat <<EOF

==> Finish complete. Watch the app come up:
    kubectl -n kubeshowcase get pods
    curl -sk https://app.192.168.1.27.nip.io/api/stats
EOF
