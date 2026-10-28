#!/usr/bin/env bash
# Create/complete .env. Idempotent: existing values are left alone; only empty ones and CHANGE_ME get filled.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
ensure_brew_path

ENV="$CHI_ROOT/.env"

if [ ! -f "$ENV" ]; then
  cp "$CHI_ROOT/.env.example" "$ENV"
  chmod 600 "$ENV"
  ok "Created .env from .env.example"
fi

# After a repo upgrade .env.example may have new keys: append them to .env (with the template default), keep existing ones
while IFS= read -r line; do
  key="${line%%=*}"
  if ! grep -q "^${key}=" "$ENV"; then
    printf '%s\n' "$line" >>"$ENV"
    ok "Added new setting $key"
  fi
done <<EOF
$(grep -E '^[A-Z_][A-Z0-9_]*=' "$CHI_ROOT/.env.example")
EOF

fill_if_empty() {
  local key="$1" value="$2" cur
  cur="$(get_kv "$ENV" "$key")"
  if [ -z "$cur" ] || printf '%s' "$cur" | grep -q CHANGE_ME; then
    set_kv "$ENV" "$key" "$value"
    ok "$key set"
  fi
}

fill_if_empty DATA_DIR "$HOME/srv/data"
fill_if_empty MEDIA_DIR "$HOME/srv/data/media"
fill_if_empty RESTIC_PASSWORD_FILE "$HOME/.config/chi/restic-password"
fill_if_empty OPEN_WEBUI_SECRET_KEY "$(rand_hex 32)"
fill_if_empty N8N_ENCRYPTION_KEY "$(rand_hex 32)"
fill_if_empty CLASH_SECRET "$(rand_hex 16)"
# LiteLLM refuses to start without a master key, and requires the sk- prefix
fill_if_empty FIRECRAWL_LLM_KEY "sk-$(rand_hex 24)"
fill_if_empty NTFY_TOPIC "chi-$(rand_alnum 20)"

# Default TZ to the host's zone (/etc/localtime -> .../zoneinfo/Area/City); UTC if it can't be read.
# Only when TZ is empty, so a zone you set by hand survives re-runs.
tz=""
if [ -L /etc/localtime ]; then
  tz="$(readlink /etc/localtime | sed 's#.*zoneinfo/##')"
fi
fill_if_empty TZ "${tz:-UTC}"

if have tailscale; then
  fqdn="$(tailscale status --json 2>/dev/null | jq -r '.Self.DNSName // empty' 2>/dev/null | sed 's/\.$//' || true)"
  if [ -n "${fqdn:-}" ]; then
    old_fqdn="$(get_kv "$ENV" TS_FQDN)"
    set_kv "$ENV" TS_FQDN "$fqdn"
    ok "TS_FQDN=$fqdn"
    [ "$old_fqdn" != "$fqdn" ] && warn "TS_FQDN changed: run 'chi up' to recreate running containers so they pick up the new name"
  else
    warn "Tailscale is not logged in; leaving TS_FQDN empty (run 'chi init' again after 'chi bootstrap tailscale')"
  fi
fi

# restic password file
pwfile="$(get_kv "$ENV" RESTIC_PASSWORD_FILE)"
if [ ! -f "$pwfile" ]; then
  mkdir -p "$(dirname "$pwfile")"
  rand_alnum 40 >"$pwfile"
  chmod 600 "$pwfile"
  warn "Generated restic password: $pwfile"
  warn "-> Save its contents in your password manager now. Without it, your backups are just random bytes."
fi

mkdir -p "$(get_kv "$ENV" DATA_DIR)"
ok ".env ready: ${ENV} (run 'chi up' after editing)"
