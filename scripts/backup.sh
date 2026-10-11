#!/usr/bin/env bash
# Back up $DATA_DIR with restic.
#
# Strategy (and why):
#   1. Copying the files of SQLite apps (Uptime Kuma, Vaultwarden, n8n, Open WebUI) mid-write can yield a corrupt
#      database. Simplest reliable fix: briefly stop those containers -> snapshot -> start again. Incrementals take
#      tens of seconds.
#   2. Immich's Postgres stays up; pg_dumpall exports SQL (the officially recommended way) and the raw postgres
#      directory is excluded.
#   3. The Immich photo library is append-only files, so back it up online without stopping (otherwise the first
#      few-hundred-GB run would mean a long outage).
#
# Restore drill: see docs/operations.md. A backup you've never restored is not a backup.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
ensure_brew_path
load_env
have restic || die "restic not installed (brew install restic)"
export RESTIC_REPOSITORY RESTIC_PASSWORD_FILE

action="${1:-run}"

case "$action" in
  init)
    restic cat config >/dev/null 2>&1 && { ok "Repository already exists: $RESTIC_REPOSITORY"; exit 0; }
    restic init
    ok "restic repository initialized: $RESTIC_REPOSITORY"
    ;;
  snapshots) restic snapshots ;;
  check)     restic check --read-data-subset=5% ;;
  run)
    restic cat config >/dev/null 2>&1 || die "Repository unavailable: ${RESTIC_REPOSITORY} (external disk mounted? If never initialized, run chi backup init first)"
    require_docker

    stacks="$(resolve_stacks)"

    # --- Immich: export the database online ---
    if docker ps --format '{{.Names}}' | grep -qx immich_postgres; then
      log "Exporting the Immich database"
      docker exec immich_postgres pg_dumpall --clean --if-exists --username=postgres \
        | gzip >"$DATA_DIR/immich/db-dump/immich.sql.gz.tmp"
      mv "$DATA_DIR/immich/db-dump/immich.sql.gz.tmp" "$DATA_DIR/immich/db-dump/immich.sql.gz"
    fi

    # --- App data: stop containers -> back up -> start (the trap brings them back up even on error) ---
    stopped=""
    restart_all() {
      for s in $stopped; do compose "$s" start >/dev/null 2>&1 || warn "$s failed to start; run chi up $s by hand"; done
    }
    trap restart_all EXIT
    for s in $stacks; do
      [ "$s" = photos ] && continue
      log "Stopping $s"
      compose "$s" stop >/dev/null
      stopped="$stopped $s"
    done

    log "Backing up app data (excluding the Immich photo library)"
    # Media files are not backed up (re-downloadable, and a 256GB disk can't hold two copies). Jellyfin config and
    # watch history live in $DATA_DIR/jellyfin and are backed up
    restic backup "$DATA_DIR" \
      --exclude "$DATA_DIR/immich" \
      --exclude "${MEDIA_DIR:-$DATA_DIR/media}" \
      --exclude "$DATA_DIR/jellyfin/cache" \
      --tag apps --host "${CHI_HOSTNAME:-chi-mini}"

    restart_all
    stopped=""
    trap - EXIT
    ok "Services restored"

    # --- Immich photo library + database export: online backup ---
    if [ -d "$DATA_DIR/immich" ]; then
      log "Backing up the Immich photo library + database export (online)"
      restic backup "$DATA_DIR/immich/library" "$DATA_DIR/immich/db-dump" \
        --tag photos --host "${CHI_HOSTNAME:-chi-mini}"
    fi

    # Also back up .env (holds the n8n encryption key etc.) - it lives in the repo directory but not in git
    restic backup "$CHI_ROOT/.env" --tag config --host "${CHI_HOSTNAME:-chi-mini}"

    log "Pruning old snapshots: keep 7 daily / 4 weekly / 6 monthly"
    restic forget --prune --group-by host,tags \
      --keep-daily 7 --keep-weekly 4 --keep-monthly 6
    ok "Backup done"
    ;;
  *) die "Usage: chi backup [init|run|snapshots|check]" ;;
esac
