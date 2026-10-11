#!/usr/bin/env bash
# Immich's compose file changes often and is version-coupled (server / ML / Postgres extension versions must match);
# upstream explicitly recommends using their released docker-compose.yml rather than rewriting it. So it is not
# committed here; we pull the latest upstream release instead.
#
# Produces: stacks/photos/compose.yaml (upstream, unmodified) and stacks/photos/.env (upstream template + our
# paths/password). Our changes live only in compose.override.yaml (committed), so re-fetching on upgrade never conflicts.
#
# Usage: stacks/photos/fetch.sh [--force]   --force re-downloads compose.yaml (the password in .env is kept)
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/../../scripts/lib.sh"
load_env

BASE=https://github.com/immich-app/immich/releases/latest/download

if [ ! -f "$DIR/compose.yaml" ] || [ "${1:-}" = "--force" ]; then
  log "Downloading the upstream Immich docker-compose.yml"
  curl -fsSL "$BASE/docker-compose.yml" -o "$DIR/compose.yaml"
  curl -fsSL "$BASE/example.env" -o "$DIR/example.env"
  ok "Updated $DIR/compose.yaml - read the Immich release notes before upgrading, they occasionally break things"
fi

if [ ! -f "$DIR/.env" ]; then
  cp "$DIR/example.env" "$DIR/.env"
  chmod 600 "$DIR/.env"
  set_kv "$DIR/.env" DB_PASSWORD "$(rand_alnum 32)"
fi
# Sync paths and timezone every time (so a changed DATA_DIR is picked up)
set_kv "$DIR/.env" UPLOAD_LOCATION "$DATA_DIR/immich/library"
set_kv "$DIR/.env" DB_DATA_LOCATION "$DATA_DIR/immich/postgres"
set_kv "$DIR/.env" TZ "$TZ"
mkdir -p "$DATA_DIR/immich/library" "$DATA_DIR/immich/postgres" "$DATA_DIR/immich/db-dump"
ok "Immich .env ready (data in $DATA_DIR/immich)"
