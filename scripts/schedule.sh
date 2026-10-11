#!/usr/bin/env bash
# Install launchd scheduled jobs (macOS's cron). Why not cron: on macOS cron is "legacy", jobs missed during
# sleep are never caught up, and permissions (TCC) are harder to manage. launchd is Apple's supported way.
#
# Jobs:
#   backup       daily BACKUP_HOUR:17   chi backup run
#   media-clean  daily 05:47            chi media clean (installed only when the media stack is enabled)
#   media-iptv   daily 05:27            chi media iptv (same; live-TV sources change URLs often, so re-probe them daily)
set -euo pipefail
. "$(dirname "$0")/lib.sh"
require_macos
load_env

AGENTS="$HOME/Library/LaunchAgents"
TMPL="$CHI_ROOT/launchd/job.plist.tmpl"

install_job() {
  local name="$1" cmd="$2" sub="$3" hour="$4" minute="$5"
  local label="com.chi-service.$name" dest="$AGENTS/com.chi-service.$name.plist"
  TPL_LABEL="$label" TPL_CHI_ROOT="$CHI_ROOT" TPL_HOME="$HOME" TPL_CMD="$cmd" TPL_SUB="$sub" \
  TPL_HOUR="$hour" TPL_MINUTE="$minute" TPL_NAME="$name" render_tmpl "$TMPL" >"$dest"
  plutil -lint "$dest" >/dev/null
  launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$dest"
  ok "${name}: daily ${hour}:${minute} -> chi $cmd ${sub} (log ~/Library/Logs/chi-service/${name}.log)"
}

remove_job() {
  local label="com.chi-service.$1"
  launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
  rm -f "$AGENTS/$label.plist"
}

# External heartbeat: ping healthchecks.io every 5 minutes. When the whole server goes down (power, network, freeze)
# Kuma goes down with it and can't alert, so only an outside service noticing "no heartbeat" can.
install_heartbeat() {
  local label=com.chi-service.heartbeat dest="$AGENTS/com.chi-service.heartbeat.plist"
  if [ -z "${HC_PING_URL:-}" ]; then
    remove_job heartbeat
    return 0
  fi
  cat >"$dest" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>${label}</string>
  <key>ProgramArguments</key>
  <array><string>/usr/bin/curl</string><string>-fsS</string><string>-m</string><string>10</string><string>--retry</string><string>3</string><string>-o</string><string>/dev/null</string><string>${HC_PING_URL}</string></array>
  <key>StartInterval</key><integer>300</integer>
  <key>RunAtLoad</key><true/>
</dict>
</plist>
PLIST
  plutil -lint "$dest" >/dev/null
  launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$dest"
  ok "heartbeat: pings the external heartbeat every 5 minutes"
}

case "${1:-install}" in
  install)
    mkdir -p "$AGENTS" "$HOME/Library/Logs/chi-service"
    if [ -n "${RESTIC_REPOSITORY:-}" ]; then
      install_job backup backup run "${BACKUP_HOUR:-4}" 17
    else
      remove_job backup
      warn "RESTIC_REPOSITORY is empty: not installing the daily backup"
    fi
    install_heartbeat
    case " $(resolve_stacks) " in
      *" media "*) install_job media-clean media clean 5 47; install_job media-iptv media iptv 5 27 ;;
      *) remove_job media-clean; remove_job media-iptv ;;
    esac
    [ -n "${RESTIC_REPOSITORY:-}" ] && log "Trigger a test backup by hand: launchctl kickstart -k gui/$(id -u)/com.chi-service.backup"
    true
    ;;
  uninstall)
    remove_job backup; remove_job media-clean; remove_job media-iptv; remove_job heartbeat
    ok "Removed all scheduled jobs"
    ;;
  *) die "Usage: chi schedule [install|uninstall]" ;;
esac
