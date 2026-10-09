#!/usr/bin/env bash
# Restore a backup made by backup.sh:
#   sudo bash restore.sh backups/db-2026-10-10-0230.dump [backups/storage-2026-10-10-0230.tar.gz]
# WARNING: replaces the current database (and the photos, if the second file is given) with the backup.
set -euo pipefail
cd "$(dirname "$0")"
DUMP=$(realpath "${1:?usage: restore.sh <db-dump> [storage-tar.gz]}")
STORE=${2:+$(realpath "$2")}
[ -s "$DUMP" ] || { echo "Backup file not found or empty: $DUMP"; exit 1; }
if [ -n "$STORE" ]; then
  tar tzf "$STORE" >/dev/null || { echo "Photo archive is damaged: $STORE"; exit 1; }   # check before deleting anything
fi
read -rp "This REPLACES all current data with $(basename "$DUMP"). Type YES to continue: " ok
[ "$ok" = "YES" ] || exit 1
trap 'docker compose start api >/dev/null' EXIT                    # the API always comes back, even after an error
docker compose stop api
docker compose exec -T db psql -U jbaya -d postgres -c "DROP DATABASE IF EXISTS jbaya WITH (FORCE);" -c "CREATE DATABASE jbaya;"
docker compose exec -T db pg_restore -U jbaya -d jbaya --no-owner < "$DUMP"
if [ -n "$STORE" ]; then
  docker compose run --rm -T --no-deps -v "$(dirname "$STORE"):/backup:ro" --entrypoint sh api \
    -c "rm -rf /srv/storage/* && tar xzf /backup/$(basename "$STORE") -C /srv"
fi
echo "Restored from $(basename "$DUMP")"
