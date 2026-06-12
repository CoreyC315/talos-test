#!/bin/sh
# pg_dump -> gzip -> MinIO. Expects DATABASE_URL, S3_ENDPOINT, S3_ACCESS_KEY, S3_SECRET_KEY.
set -eu
STAMP=$(date -u +%Y%m%d-%H%M%S)
OUT=/tmp/ks-${STAMP}.sql.gz
echo "dumping database..."
pg_dump "${DATABASE_URL}" | gzip > "${OUT}"
SIZE=$(wc -c < "${OUT}")
echo "dump complete: ${OUT} (${SIZE} bytes)"
export MC_CONFIG_DIR=/tmp/.mc
mc alias set s3 "${S3_ENDPOINT}" "${S3_ACCESS_KEY}" "${S3_SECRET_KEY}" >/dev/null
mc cp "${OUT}" "s3/pg-dumps/$(basename "${OUT}")"
echo "uploaded to pg-dumps/$(basename "${OUT}")"
