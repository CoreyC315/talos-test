# Nightly logical-backup image: pg_dump + MinIO client, non-root, read-only rootfs friendly
FROM minio/mc:RELEASE.2025-05-21T01-59-54Z AS mc

FROM alpine:3.21
RUN apk add --no-cache postgresql17-client gzip && \
    adduser -D -u 65532 backup
COPY --from=mc /usr/bin/mc /usr/local/bin/mc
COPY entrypoint.sh /entrypoint.sh
USER 65532:65532
ENTRYPOINT ["/bin/sh", "/entrypoint.sh"]
