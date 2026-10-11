#!/usr/bin/env bash
# End-to-end check: run on the client (e.g. your laptop) to verify everything on the server as a user sees it.
#   chi remote-check [ssh-host]     default ssh host = chi-mini
# Checks: Tailscale reachability and direct connection, SSH, the public entry, every tailnet service, LAN Jellyfin,
# and chi doctor on the server.
# No local .env needed; TS_FQDN / PUBLIC_DOMAIN are read from the server.
# CHI_REMOTE_DIR: the repo checkout on the server (relative to its home, or absolute). Default: the first of
# chi-server, chi-service (legacy name) found in the remote home.
set -uo pipefail
. "$(dirname "$0")/lib.sh"

host="${1:-chi-mini}"
fails=0
bad() { warn "$*"; fails=$((fails + 1)); }
code() { curl -s -o /dev/null -m 8 -w '%{http_code}' "$1" 2>/dev/null || true; }

# type -P finds the real binary: on the server lib.sh wraps tailscale in a function with --socket, which doesn't apply here
TSBIN="$(type -P tailscale || echo /Applications/Tailscale.app/Contents/MacOS/Tailscale)"

log "Tailscale"
if out="$("$TSBIN" ping -c 3 "$host" 2>&1)"; then
  last="$(printf '%s\n' "$out" | tail -1)"
  case "$last" in
    *DERP*) warn "Relayed: ${last} (works, but slow; see port forwarding in docs/remote-access.md)" ;;
    *pong*) ok "$last" ;;
    *) bad "Unexpected tailscale ping result: ${last}" ;;
  esac
else
  bad "tailscale ping failed (is Tailscale running on this machine?)"
fi

log "SSH"
if ssh -o BatchMode=yes -o ConnectTimeout=8 "$host" true 2>/dev/null; then
  ok "ssh ${host} works without a password"
else
  bad "ssh ${host} failed (check Tailscale / ~/.ssh/config / authorized_keys)"
  exit "$fails"
fi

if [ -z "${CHI_REMOTE_DIR:-}" ]; then
  CHI_REMOTE_DIR="$(ssh "$host" 'for d in chi-server chi-service; do [ -d "$d" ] && { echo "$d"; break; }; done' 2>/dev/null || true)"
fi
if [ -z "$CHI_REMOTE_DIR" ]; then
  bad "No chi-server or chi-service checkout in ${host}'s home; set CHI_REMOTE_DIR to the repo path on ${host}"
  exit "$fails"
fi
ok "Repo on ${host}: ${CHI_REMOTE_DIR}"

# Remote paths are left unquoted on purpose so the remote shell expands a ~ in CHI_REMOTE_DIR.
# shellcheck disable=SC2029  # $1 and CHI_REMOTE_DIR are meant to expand locally
env_get() { ssh "$host" "grep '^$1=' $CHI_REMOTE_DIR/.env | cut -d= -f2- | tr -d \"'\\\"\"" 2>/dev/null; }
TS="$(env_get TS_FQDN)"
PUB="$(env_get PUBLIC_DOMAIN)"
STACKS="$(env_get CHI_STACKS)"

if [ -n "$PUB" ] && case " $STACKS " in *" public "*) true ;; *) false ;; esac; then
  log "Public (Cloudflare Tunnel)"
  c="$(code "https://$PUB")"
  [ "$c" = 200 ] && ok "https://${PUB} -> ${c}" || bad "https://${PUB} -> ${c} (530/1033 = cloudflared not connected, most likely nobody is logged in on the server)"
fi

log "tailnet services (https://${TS})"
check() {  # stack port name
  case " $STACKS " in *" $1 "*) ;; *) return 0 ;; esac
  local url="https://$TS$2" c
  c="$(code "$url")"
  case "$c" in
    200|301|302|307|401) ok "$3 ${url} -> ${c}" ;;
    *) bad "$3 ${url} -> ${c}" ;;
  esac
}
check core  ""      Home
check core  :8001   "Uptime Kuma"
check core  :8002   Dozzle
check ai    :8003   "Open WebUI"
check media :8009   Jellyfin
check media :8010   MeTube
c="$(code "https://$TS:8008")"
[ "$c" = 200 ] && ok "Landing page https://${TS}:8008 -> ${c}" || warn "Landing page :8008 -> ${c} (never ran chi onboard?)"

if case " $STACKS " in *" media "*) true ;; *) false ;; esac; then
  log "LAN Jellyfin (for TV boxes)"
  ip="$(ssh "$host" 'ipconfig getifaddr en0 || ipconfig getifaddr en1' 2>/dev/null)"
  c="$(code "http://$ip:8096/")"
  case "$c" in 200|302) ok "http://${ip}:8096 -> ${c}" ;; *) warn "http://${ip}:8096 -> ${c} (expected to fail when you're not on the same LAN)" ;; esac
fi

log "chi doctor on the server"
# shellcheck disable=SC2029  # CHI_REMOTE_DIR expands locally
if ssh "$host" "cd $CHI_REMOTE_DIR && PATH=/opt/homebrew/bin:\$HOME/.orbstack/bin:\$PATH bin/chi doctor" >/dev/null 2>&1; then
  ok "doctor: all good"
else
  bad "doctor found problems: ssh ${host} 'cd ${CHI_REMOTE_DIR} && bin/chi doctor'"
fi

echo
if [ "$fails" -eq 0 ]; then ok "End-to-end: all passed"; else warn "${fails} check(s) failed"; fi
exit "$fails"
