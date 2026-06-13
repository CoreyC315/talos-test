#!/usr/bin/env bash
# Time-capsule backup → Synology NAS (Celestia, NFS /volume1/backups, exported to the LAN).
# Bundles everything you'd want to "come back to later and see what was made", plus the crown
# jewels needed to rebuild/reconnect (encrypted). Designed to be re-run anytime (timestamped).
#
# Contents of each capsule:
#   repo.bundle              git bundle of the WHOLE repo+history (clone-able even if GitHub is gone)
#   cluster-snapshot.md      human-readable "what was running": nodes, ArgoCD apps, versions
#   manifests/               raw kubectl dumps (apps, nodes, pods, CRDs of interest)
#   etcd-<ts>.snap           talosctl etcd snapshot (true DR restore point)
#   secrets.tar.enc          age-passphrase-encrypted: age key + kube/talosconfig + TF state
#   MANIFEST.txt             index + restore notes
#
# Usage:
#   ./load-and-chaos/backup-to-nas.sh
# Env (all optional):
#   NAS_HOST=192.168.1.210  NAS_EXPORT=/volume1/backups   (NFS source)
#   NAS_DIR=/path           (use an ALREADY-mounted dir, skip the sudo mount)
#   BACKUP_PASSPHRASE=...    (else a strong one is generated and printed — SAVE IT)
set -euo pipefail
export COPYFILE_DISABLE=1  # no macOS ._ AppleDouble files in the tarballs
cd "$(dirname "$0")/.."
REPO="$PWD"
export KUBECONFIG="${KUBECONFIG:-$REPO/talos/clusterconfig/kubeconfig}"
export TALOSCONFIG="${TALOSCONFIG:-$REPO/talos/clusterconfig/talosconfig}"

NAS_HOST="${NAS_HOST:-192.168.1.210}"
NAS_EXPORT="${NAS_EXPORT:-/volume1/backups}"
SUBDIR="kubeshowcase"
TS="$(date +%Y%m%d-%H%M%S)"
STAGE="$(mktemp -d /tmp/ks-capsule.XXXXXX)"
CAP="$STAGE/kubeshowcase-$TS"
mkdir -p "$CAP/manifests"
echo "==> Staging time capsule in $CAP"

# 1. Full repo as a single clone-able bundle (history + all branches/tags).
git -C "$REPO" bundle create "$CAP/repo.bundle" --all >/dev/null
echo "  ✓ repo.bundle ($(git -C "$REPO" rev-list --count HEAD) commits)"

# 2. Human-readable cluster snapshot + raw manifests (best-effort; skips if cluster unreachable).
if kubectl version >/dev/null 2>&1; then
  {
    echo "# KubeShowcase cluster snapshot — $TS"
    echo; echo "## Nodes"; echo '```'; kubectl get nodes -o wide 2>&1; echo '```'
    echo; echo "## Argo CD applications"; echo '```'
    kubectl -n argocd get applications -o custom-columns='NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status' 2>&1; echo '```'
    echo; echo "## Versions"; echo '```'
    echo "talos:   $(talosctl version --short 2>/dev/null | tr '\n' ' ')"
    echo "k8s:     $(kubectl version 2>/dev/null | tr '\n' ' ')"
    echo "cilium:  $(kubectl -n kube-system get ds cilium -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null)"
    echo '```'
    echo; echo "## Pods (all namespaces)"; echo '```'; kubectl get pods -A -o wide 2>&1; echo '```'
  } > "$CAP/cluster-snapshot.md"
  kubectl get applications -n argocd -o yaml > "$CAP/manifests/argocd-applications.yaml" 2>/dev/null || true
  kubectl get nodes -o yaml                  > "$CAP/manifests/nodes.yaml" 2>/dev/null || true
  kubectl get pods -A -o wide                > "$CAP/manifests/pods.txt" 2>/dev/null || true
  echo "  ✓ cluster-snapshot.md + manifests/"
else
  echo "  ⚠ cluster unreachable — skipping live snapshot (repo + secrets still captured)"
fi

# 3. etcd snapshot (DR restore point) — best-effort.
if talosctl -n 192.168.1.20 version >/dev/null 2>&1; then
  talosctl -n 192.168.1.20 etcd snapshot "$CAP/etcd-$TS.snap" >/dev/null 2>&1 \
    && echo "  ✓ etcd-$TS.snap" || echo "  ⚠ etcd snapshot skipped"
fi

# 4. The crown jewels, age-passphrase-encrypted.
GEN_PASS=0
if [ -z "${BACKUP_PASSPHRASE:-}" ]; then BACKUP_PASSPHRASE="$(openssl rand -base64 24)"; GEN_PASS=1; fi
SECRETS="$STAGE/secrets"; mkdir -p "$SECRETS"
cp -f "$HOME/.config/sops/age/keys.txt"        "$SECRETS/age-keys.txt"      2>/dev/null || true
cp -f "$REPO/talos/clusterconfig/kubeconfig"   "$SECRETS/kubeconfig"        2>/dev/null || true
cp -f "$REPO/talos/clusterconfig/talosconfig"  "$SECRETS/talosconfig"       2>/dev/null || true
cp -f "$REPO/terraform/terraform.tfstate"      "$SECRETS/terraform.tfstate" 2>/dev/null || true
tar -C "$SECRETS" -czf - . \
  | openssl enc -aes-256-cbc -pbkdf2 -salt -pass "pass:$BACKUP_PASSPHRASE" -out "$CAP/secrets.tar.enc"
rm -rf "$SECRETS"
echo "  ✓ secrets.tar.enc (age key, kube/talosconfig, TF state)"

# 5. Index / restore notes.
cat > "$CAP/MANIFEST.txt" <<EOF
KubeShowcase time capsule — $TS
================================
repo.bundle            git clone repo.bundle kubeshowcase   # full history
cluster-snapshot.md    what was running at capture time
manifests/             raw kubectl dumps
etcd-$TS.snap          talosctl -n <cp> etcd snapshot recovery file (DR)
secrets.tar.enc        openssl enc -d -aes-256-cbc -pbkdf2 -pass pass:PASS -in secrets.tar.enc | tar xz
                       (age key, kubeconfig, talosconfig, terraform.tfstate)

Rebuild from scratch:   cd terraform && terraform apply   (see terraform/README.md)
Decrypt secrets:        openssl enc -d -aes-256-cbc -pbkdf2 -in secrets.tar.enc | tar xz   [passphrase below]
EOF

# 6. Tar the capsule and ship to the NAS.
TARBALL="$STAGE/kubeshowcase-$TS.tar.gz"
tar -C "$STAGE" -czf "$TARBALL" "kubeshowcase-$TS"
SIZE="$(du -h "$TARBALL" | cut -f1)"
echo "==> Capsule built: $SIZE"

# Hands-off delivery via a cluster pod with an NFS volume (no sudo). The Synology export
# /volume1/backups is world-writable to the LAN, so a kubelet-mounted NFS pod can receive the
# capsule via `kubectl cp`. Falls back to a local sudo NFS mount, then to leaving it on disk.
ship_via_cluster() { # tarball
  local tb="$1" ns=ks-backup pod=nas-uploader
  kubectl get ns "$ns" >/dev/null 2>&1 || kubectl create ns "$ns" >/dev/null
  kubectl label ns "$ns" pod-security.kubernetes.io/enforce=baseline --overwrite >/dev/null
  kubectl -n "$ns" delete pod "$pod" --ignore-not-found --now >/dev/null 2>&1
  cat <<YAML | kubectl apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata: { name: $pod, namespace: $ns }
spec:
  restartPolicy: Never
  containers:
    - name: u
      image: docker.io/library/busybox:1.37.0
      command: ["sleep", "600"]
      volumeMounts: [{ name: nas, mountPath: /nas }]
  volumes:
    - name: nas
      nfs: { server: $NAS_HOST, path: $NAS_EXPORT }
YAML
  kubectl -n "$ns" wait --for=condition=Ready "pod/$pod" --timeout=150s >/dev/null
  kubectl -n "$ns" exec "$pod" -- mkdir -p "/nas/$SUBDIR"
  kubectl cp "$tb" "$ns/$pod:/nas/$SUBDIR/$(basename "$tb")"
  kubectl -n "$ns" exec "$pod" -- ls -lh "/nas/$SUBDIR/"
  kubectl -n "$ns" delete pod "$pod" --ignore-not-found --wait=false >/dev/null
}

if [ -n "${NAS_DIR:-}" ]; then
  mkdir -p "$NAS_DIR/$SUBDIR"; cp "$TARBALL" "$NAS_DIR/$SUBDIR/"; ls -lh "$NAS_DIR/$SUBDIR/" | tail -3
elif [ "${VIA_SUDO_MOUNT:-0}" != 1 ] && kubectl version >/dev/null 2>&1; then
  echo "==> Shipping to NAS via a cluster NFS pod (no sudo)…"
  ship_via_cluster "$TARBALL"
else
  MNT="$(mktemp -d /tmp/ks-nas.XXXXXX)"
  echo "==> Mounting $NAS_HOST:$NAS_EXPORT (sudo, NFS)…"
  if sudo mount -t nfs -o resvport,vers=3 "$NAS_HOST:$NAS_EXPORT" "$MNT" 2>/dev/null; then
    mkdir -p "$MNT/$SUBDIR"; cp "$TARBALL" "$MNT/$SUBDIR/"; ls -lh "$MNT/$SUBDIR/" | tail -3
    sync; sudo umount "$MNT" && rmdir "$MNT"
  else
    echo "  ⚠ Could not reach NAS. Capsule left at: $TARBALL  (set NAS_DIR=<path> or run with cluster up)"
    [ "$GEN_PASS" = 1 ] && echo "    !!! SAVE THIS PASSPHRASE for secrets.tar.enc: $BACKUP_PASSPHRASE"
    exit 0
  fi
fi
rm -rf "$STAGE"
echo "==> Done → NAS:$NAS_EXPORT/$SUBDIR/kubeshowcase-$TS.tar.gz"
[ "$GEN_PASS" = 1 ] && {
  echo
  echo "  ########################################################################"
  echo "  #  SAVE THIS — passphrase for secrets.tar.enc (no recovery without it): #"
  echo "  #  $BACKUP_PASSPHRASE"
  echo "  ########################################################################"
}
