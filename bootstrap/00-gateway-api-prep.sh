#!/usr/bin/env bash
# Gateway API CRDs prepared for Cilium 1.19 — the TLSRoute saga (gotcha #3), encoding the
# ACTUAL working sequence. Reused by bootstrap/01-bootstrap-core.sh AND terraform/bootstrap.tf
# so there is one source of truth for this fiddly step.
#
# The problem: gateway-api v1.5 ships a `safe-upgrades` ValidatingAdmissionPolicy that blocks
# installing CRDs older than v1.5. But Cilium 1.19's Gateway controller indexes TLSRoute at
# **v1alpha2**, and (with Gateway API enabled) its agents require the TLSRoute CRD to EXIST.
# So we drop the downgrade guard and install TLSRoute at v1alpha2 (from gateway-api v1.3.0).
set -euo pipefail

GATEWAY_API_VERSION=${GATEWAY_API_VERSION:-v1.5.1} # standard channel — see versions.lock.md
TLSROUTE_SRC=${TLSROUTE_SRC:-v1.3.0}              # gateway-api release whose TLSRoute is v1alpha2

# Right after `talosctl bootstrap` the apiserver/VIP can still be flapping (nodes are NotReady,
# no CNI yet) — a fresh `terraform apply` hits this and gets "connection refused" on the VIP.
# Wait until the k8s API is stably serving before applying CRDs (idempotent; safe on re-runs).
echo "==> Waiting for the Kubernetes API (VIP) to be stably reachable…"
for i in $(seq 1 60); do
  kubectl get --raw=/readyz >/dev/null 2>&1 && { echo "    API ready."; break; }
  [ "$i" = 60 ] && { echo "    API never became ready" >&2; exit 1; }
  sleep 5
done

echo "==> Gateway API ${GATEWAY_API_VERSION} standard CRDs (Gateway, HTTPRoute, ReferenceGrant, GRPCRoute)"
kubectl apply -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml"

echo "==> Drop the v1.5 downgrade guard so alpha CRD versions can be enabled"
kubectl delete validatingadmissionpolicybinding safe-upgrades.gateway.networking.k8s.io --ignore-not-found
kubectl delete validatingadmissionpolicy        safe-upgrades.gateway.networking.k8s.io --ignore-not-found

echo "==> Ensure TLSRoute is SERVED at v1alpha2 (Cilium 1.19's Gateway controller indexes it there)"
if kubectl get crd tlsroutes.gateway.networking.k8s.io >/dev/null 2>&1; then
  # gateway-api >=1.5 now ships tlsroutes in the STANDARD bundle (v1 storage) with v1alpha2 defined
  # but served=false. Applying the standalone v1alpha2-only CRD over it is REJECTED ("v1 was a
  # storage version, must remain in spec.versions"), so flip v1alpha2 to served on the existing CRD.
  idx=$(kubectl get crd tlsroutes.gateway.networking.k8s.io -o json \
    | python3 -c 'import json,sys; v=json.load(sys.stdin)["spec"]["versions"]; print(next((i for i,x in enumerate(v) if x["name"]=="v1alpha2"), -1))')
  if [ "${idx:-1}" -ge 0 ]; then
    kubectl patch crd tlsroutes.gateway.networking.k8s.io --type=json \
      -p "[{\"op\":\"replace\",\"path\":\"/spec/versions/${idx}/served\",\"value\":true}]"
  fi
else
  # gateway-api <1.5: the standard bundle has NO TLSRoute — install the v1alpha2 CRD directly.
  kubectl apply -f "https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/${TLSROUTE_SRC}/config/crd/experimental/gateway.networking.k8s.io_tlsroutes.yaml"
fi
