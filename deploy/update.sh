#!/usr/bin/env bash
# Install a new version: pulls the code, backs up first, rebuilds and restarts (the database schema updates itself).
#   sudo bash update.sh
set -euo pipefail
cd "$(dirname "$0")"
bash backup.sh
git -C .. pull --ff-only
docker compose up -d --build
docker image prune -f >/dev/null
echo "Updated. Upload the new web build to deploy/web if the app changed (see README.md)."
