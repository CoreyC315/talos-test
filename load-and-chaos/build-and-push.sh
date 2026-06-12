#!/usr/bin/env bash
# Builds + pushes all KubeShowcase images (linux/amd64) and records the digests
# in apps/kubeshowcase-manifests/images.lock. ghcr.io login required beforehand.
set -euo pipefail
cd "$(dirname "$0")/.."

REGISTRY=ghcr.io/coreyc315
VERSION="${1:-1.0.0}"
LOCK=apps/kubeshowcase-manifests/images.lock

: > "${LOCK}.tmp"
for comp in api worker frontend pgdump; do
  img="${REGISTRY}/ks-${comp}:${VERSION}"
  echo "==> ${img}"
  docker buildx build --platform linux/amd64 -t "${img}" --push "app-src/${comp}"
  digest=$(docker buildx imagetools inspect "${img}" --format '{{json .Manifest}}' | jq -r .digest)
  echo "ks-${comp} ${img}@${digest}" >> "${LOCK}.tmp"
done
mv "${LOCK}.tmp" "${LOCK}"
echo "==> digests:"
cat "${LOCK}"
