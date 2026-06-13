#!/usr/bin/env bash
# Builds all KubeShowcase images (linux/amd64) locally and pushes them to the
# in-cluster registry (plain HTTP — crane --insecure, no Docker daemon config needed).
# Records digests in workloads/kubeshowcase/images.lock.
set -euo pipefail
cd "$(dirname "$0")/.."

REGISTRY="${REGISTRY:-192.168.1.28:5000}"
VERSION="${1:-1.0.0}"
LOCK=workloads/kubeshowcase/images.lock

: > "${LOCK}.tmp"
for comp in api worker frontend pgdump; do
  ref="${REGISTRY}/ks-${comp}:${VERSION}"
  echo "==> build ${ref}"
  docker buildx build --platform linux/amd64 --load -t "${ref}" "app-src/${comp}"
  tarball=$(mktemp /tmp/ks-img-XXXX.tar)
  docker save "${ref}" -o "${tarball}"
  echo "==> push ${ref}"
  crane push --insecure "${tarball}" "${ref}"
  rm -f "${tarball}"
  digest=$(crane digest --insecure "${ref}")
  echo "ks-${comp} ${ref}@${digest}" >> "${LOCK}.tmp"
done
mv "${LOCK}.tmp" "${LOCK}"
echo "==> digests:"; cat "${LOCK}"
