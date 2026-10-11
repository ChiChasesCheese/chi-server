#!/usr/bin/env bash
# Generate the onboarding page + PAC file for you and your friends into $DATA_DIR/share; `chi serve` publishes it at
# https://<TS_FQDN>:8008. Also prints an invite text you can paste straight into a chat app.
#
# The page contains no passwords or subscriptions; the PAC only holds the Mac mini's Tailscale IP (reachable only
# inside the tailnet).
set -euo pipefail
. "$(dirname "$0")/lib.sh"
ensure_brew_path
load_env

[ -n "${TS_FQDN:-}" ] || die "TS_FQDN is empty: run chi bootstrap tailscale, then chi init"
tsip="$(ts_ip)"; [ -n "$tsip" ] || die "Could not get the Tailscale IP (check tailscale status)"
host="${TS_FQDN%%.*}"
out="$DATA_DIR/share"
mkdir -p "$out"

today="$(date '+%Y-%m-%d')"
export TPL_FQDN="$TS_FQDN" TPL_TS_IP="$tsip" TPL_PORT="${CLASH_PORT:-7890}" TPL_HOST="$host" \
  TPL_MEDIA_MAX_GB="${MEDIA_MAX_GB:-60}" TPL_GENERATED="$today"
render_tmpl "$CHI_ROOT/config/onboarding/index.html.tmpl" >"$out/index.html"
render_tmpl "$CHI_ROOT/config/onboarding/chi.pac.tmpl" >"$out/chi.pac"
ok "Generated $out/index.html and chi.pac"

if is_macos; then "$CHI_ROOT/scripts/tailscale-serve.sh" apply >/dev/null && ok "Published via chi serve at https://${TS_FQDN}:8008"; fi

cat <<MSG

-------- Admin steps (once per friend you invite) --------
 1. https://login.tailscale.com/admin/machines -> $host -> "..." -> Share... -> copy the invite link
    (first time: set up the ACL per docs/guest-access.md to limit which ports friends can reach)
 2. Jellyfin -> Dashboard -> Users -> create an account for them (you can grant only some libraries)
 3. Send them the text below:

-------- Copy to your friend --------
Hi! Here's how to get onto my home server:
1) Install Tailscale on your phone/computer (App Store / Play Store / tailscale.com/download) and sign in with any account
2) Open this invite link and accept it: <paste the link from step 1 here>
3) With Tailscale connected, open https://${TS_FQDN}:8008 - it explains how to set up iPhone / Mac, watch videos, and watch mainland-only Bilibili content
Jellyfin account: <username> / <initial password> (change it after logging in)
-------------------------------------
MSG
