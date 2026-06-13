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

echo "==> Gateway API ${GATEWAY_API_VERSION} standard CRDs (Gateway, HTTPRoute, ReferenceGrant, GRPCRoute)"
kubectl apply -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml"

echo "==> Drop the v1.5 downgrade guard, then install TLSRoute at v1alpha2 (what Cilium 1.19 indexes)"
kubectl delete validatingadmissionpolicybinding safe-upgrades.gateway.networking.k8s.io --ignore-not-found
kubectl delete validatingadmissionpolicy        safe-upgrades.gateway.networking.k8s.io --ignore-not-found
kubectl apply -f "https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/${TLSROUTE_SRC}/config/crd/experimental/gateway.networking.k8s.io_tlsroutes.yaml"
