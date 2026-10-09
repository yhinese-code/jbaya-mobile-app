#!/usr/bin/env bash
# Nightly backup: the database (all money records) + the photos/documents. Keeps 14 days.
# Set BACKUP_COPY_DIR (e.g. a mounted USB disk or a second server path) to keep a copy OFF this machine.
set -euo pipefail
umask 077          # dumps hold citizens' numbers and password hashes: owner-only files
cd "$(dirname "$0")"
STAMP=$(date +%F-%H%M)
mkdir -p backups
docker compose exec -T db pg_dump -U jbaya -d jbaya --format=custom > "backups/db-$STAMP.dump"
docker compose run --rm -T --no-deps -v "$(pwd)/backups:/backup" --entrypoint tar api \
  czf "/backup/storage-$STAMP.tar.gz" -C /srv storage
cp .env "backups/env-$STAMP" && chmod 600 "backups/env-$STAMP"
find backups -name 'db-*.dump' -mtime +14 -delete
find backups -name 'storage-*.tar.gz' -mtime +14 -delete
find backups -name 'env-*' -mtime +14 -delete
if [ -n "${BACKUP_COPY_DIR:-}" ]; then
  mkdir -p "$BACKUP_COPY_DIR" && cp "backups/db-$STAMP.dump" "backups/storage-$STAMP.tar.gz" "$BACKUP_COPY_DIR/"
fi
echo "$(date -Is) backup ok: db-$STAMP.dump"
