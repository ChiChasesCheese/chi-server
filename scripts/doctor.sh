#!/usr/bin/env bash
# Health check: read-only, changes nothing. Every ✓ / ! line tells you why it matters.
set -uo pipefail
. "$(dirname "$0")/lib.sh"
ensure_brew_path

fails=0
bad() { warn "$*"; fails=$((fails + 1)); }

log "System"
if is_macos; then
  ok "macOS $(sw_vers -productVersion) / $(uname -m)"
  [ "$(uname -m)" = arm64 ] || bad "Not Apple Silicon; some features (FileVault SSH unlock, Metal inference) are unavailable"

  pm="$(pmset -g)"
  echo "$pm" | grep -Eq '^ *sleep +0' && ok "Never sleeps" || bad "System will sleep -> chi bootstrap macos"
  echo "$pm" | grep -Eq 'autorestart +1' && ok "Powers on after power loss" || bad "Won't power on after power loss -> chi bootstrap macos"

  fw="$(/usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate 2>/dev/null)"
  case "$fw" in *enabled*) ok "Firewall on" ;; *) bad "Firewall off" ;; esac

  nc -z 127.0.0.1 22 >/dev/null 2>&1 && ok "SSH is listening" || bad "SSH is off (System Settings -> General -> Sharing -> Remote Login)"

  fv="$(fdesetup status 2>/dev/null)"
  case "$fv" in
    *"is On"*) warn "FileVault on: after a reboot the disk must be unlocked remotely or locally first (see docs/operations.md)" ;;
    *) ok "FileVault off: reboots unattended (trade-off: a stolen machine's data is readable)" ;;
  esac

  au="$(autologin_effective)"
  [ -n "$au" ] && ok "Auto-login user: ${au}" || warn "Auto-login not in effect: nobody logs in after a reboot, so Docker/Ollama won't start (System Settings -> Users & Groups -> Automatically log in as)"

  df_pct="$(df -P / | awk 'NR==2 {gsub("%",""); print $5}')"
  [ "$df_pct" -lt 85 ] && ok "System disk ${df_pct}% used" || bad "System disk ${df_pct}% used (>85%)"

  # Auto-installing macOS updates = rebooting on its own; with FileVault on it stops at the unlock screen
  amu="$(defaults read /Library/Preferences/com.apple.SoftwareUpdate AutomaticallyInstallMacOSUpdates 2>/dev/null || true)"
  [ "$amu" = 1 ] && bad "macOS updates install automatically: the Mac reboots itself, and under FileVault every service stops -> chi bootstrap macos" \
    || ok "macOS updates are not auto-installed"
else
  warn "Not macOS; skipping system checks"
fi

log "Network"
if have tailscale; then
  if tailscale status >/dev/null 2>&1; then
    ok "Tailscale online: $(tailscale ip -4 2>/dev/null | head -n1)"
  else
    bad "Tailscale not logged in -> chi bootstrap tailscale"
  fi
else
  bad "Tailscale not installed -> chi bootstrap tailscale"
fi

log "Config"
if [ -f "$CHI_ROOT/.env" ]; then
  load_env
  ok ".env present; enabled stacks: $(resolve_stacks)"
  [ -n "${TS_FQDN:-}" ] && ok "TS_FQDN=$TS_FQDN" || bad "TS_FQDN is empty -> chi init"
  if [ -n "${RESTIC_REPOSITORY:-}" ]; then
    [ -f "${RESTIC_PASSWORD_FILE:-/nonexistent}" ] && ok "restic password file present" || bad "restic password file missing -> chi init"
  else
    warn "Backup disabled (RESTIC_REPOSITORY is empty in .env)"
  fi
  [ -n "${NTFY_TOPIC:-}" ] && ok "Alerts: ntfy topic configured" || warn "Alerts not configured (NTFY_TOPIC is empty)"
  [ -n "${HC_PING_URL:-}" ] && ok "External heartbeat: configured" || warn "External heartbeat not configured (HC_PING_URL is empty; a fully offline machine won't alert)"
else
  bad "No .env -> chi init"
fi

log "Containers"
if docker_ready; then
  ok "docker available ($(docker version --format '{{.Server.Version}}' 2>/dev/null))"
  if [ -f "$CHI_ROOT/.env" ]; then
    for s in $(resolve_stacks); do
      running="$(docker ps --filter "label=com.docker.compose.project=chi-$s" --format '{{.Names}}' | tr '\n' ' ')"
      unhealthy="$(docker ps --filter "label=com.docker.compose.project=chi-$s" --filter health=unhealthy --format '{{.Names}}' | tr '\n' ' ')"
      if [ -z "$running" ]; then bad "${s}: no running containers -> chi up $s"
      elif [ -n "$unhealthy" ]; then bad "${s}: unhealthy -> ${unhealthy}(chi logs ${s})"
      else ok "${s}: $running"; fi
    done
    # If TS_FQDN in .env changed (e.g. chi up ran before Tailscale was logged in) but containers weren't recreated, they still carry localhost
    if [ -n "${TS_FQDN:-}" ]; then
      stale=""
      for c in $(docker ps --filter "name=^chi-" --format '{{.Names}}'); do
        docker inspect "$c" --format '{{range .Config.Env}}{{println .}}{{end}}' \
          | grep -qE '^(WEBUI_URL|JELLYFIN_PublishedServerUrl|N8N_HOST|WEBHOOK_URL|DOMAIN|HOMEPAGE_VAR_TS_FQDN)=(https://)?localhost' \
          && stale="$stale$c "
      done
      [ -z "$stale" ] && ok "Container hostnames match TS_FQDN" || bad "These containers still use the old hostname (localhost): ${stale}-> chi up"
    fi
  fi
else
  bad "Cannot reach docker (OrbStack/Colima not running?)"
fi

if [ -f "$CHI_ROOT/.env" ] && case " $(resolve_stacks) " in *" ai "*) true ;; *) false ;; esac; then
  log "Ollama"
  if v="$(curl -fsS --max-time 2 http://127.0.0.1:11434/api/version 2>/dev/null)"; then
    ok "Ollama online ${v}; models: $(ollama list 2>/dev/null | awk 'NR>1 {print $1}' | tr '\n' ' ')"
  else
    bad "Ollama offline -> brew services start ollama"
  fi
fi

if [ -f "$CHI_ROOT/.env" ] && case " $(resolve_stacks) " in *" media "*) true ;; *) false ;; esac; then
  log "Media"
  md="${MEDIA_DIR:-$DATA_DIR/media}"
  if [ -d "$md/Downloads" ]; then
    used_g=$(( $(du -sk "$md/Downloads" | awk '{print $1}') / 1024 / 1024 ))
    [ "$used_g" -le "${MEDIA_MAX_GB:-60}" ] && ok "Downloads ${used_g}G / limit ${MEDIA_MAX_GB:-60}G" \
      || bad "Downloads ${used_g}G is over the limit -> chi media clean (or chi schedule to install auto-cleanup)"
  else
    bad "$md/Downloads does not exist -> chi up media"
  fi
fi

if [ -f "$CHI_ROOT/.env" ] && case " $(resolve_stacks) " in *" public "*) true ;; *) false ;; esac; then
  log "Public entry (Cloudflare Tunnel)"
  if [ "$(docker inspect chi-cloudflared --format '{{.State.Running}}' 2>/dev/null || true)" != true ]; then
    bad "chi-cloudflared is not running -> chi up public"
  else
    # It logs "Registered tunnel connection" on connect and nothing while stable, so look at whichever register/disconnect/error line came last
    last="$(docker logs --tail 3000 chi-cloudflared 2>&1 | grep -E 'Registered tunnel connection|Unregistered|Connection terminated| ERR ' | tail -n1)"
    case "$last" in
      *"Registered tunnel connection"*) ok "cloudflared tunnel connected to Cloudflare" ;;
      *) bad "cloudflared tunnel not connected (bad token? no outbound network?) -> chi logs public" ;;
    esac
  fi
fi

if [ -n "${CLASH_SUBSCRIPTION_URL:-}" ]; then
  log "China split-routing proxy"
  if nc -z 127.0.0.1 "${CLASH_PORT:-7890}" >/dev/null 2>&1; then
    # Bilibili's geo-IP API: country_code is 86 for China. The "\u4e2d\u56fd" (China) name match is a fallback in case
    # country_code is ever missing; jq's \u escape keeps this file ASCII.
    via="$(curl -fsS --max-time 10 -x "http://127.0.0.1:${CLASH_PORT:-7890}" https://api.bilibili.com/x/web-interface/zone 2>/dev/null \
      | jq -r '.data | if (.country_code | tostring) == "86" or .country == "\u4e2d\u56fd" then "CN" else (.country // empty) end' 2>/dev/null || true)"
    [ "$via" = CN ] && ok "mihomo up; Bilibili sees: China" || bad "mihomo up but Bilibili sees \"${via:-unknown}\" -> chi proxy status"
  else
    bad "mihomo is not listening on :${CLASH_PORT:-7890} -> chi proxy install"
  fi
fi

echo
if [ "$fails" -eq 0 ]; then ok "All good"; else warn "$fails item(s) need attention"; fi
exit "$fails"
