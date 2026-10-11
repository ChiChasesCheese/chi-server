#!/usr/bin/env bash
# 安装 launchd 定时任务（macOS 的 cron）。为什么不用 cron：cron 在 macOS 上是“遗留”的，
# 睡眠期间错过的任务不会补跑，权限（TCC）也更难管。launchd 是 Apple 的正路。
#
# 任务：
#   backup       每天 BACKUP_HOUR:17   chi backup run
#   media-clean  每天 05:47            chi media clean（只在启用了 media stack 时安装）
#   media-iptv   每天 05:27            chi media iptv（同上；直播源经常换地址，每天重新试播一遍）
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
  ok "${name}：每天 $hour:$minute → chi $cmd ${sub}（日志 ~/Library/Logs/chi-service/$name.log）"
}

remove_job() {
  local label="com.chi-service.$1"
  launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
  rm -f "$AGENTS/$label.plist"
}

# 外部心跳：每 5 分钟 ping 一次 healthchecks.io。mini 整机掉线（断电、断网、死机）时
# Kuma 自己也挂了发不出告警，只能靠外部服务“没收到心跳”来报警。
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
  ok "heartbeat：每 5 分钟 ping 一次外部心跳"
}

case "${1:-install}" in
  install)
    mkdir -p "$AGENTS" "$HOME/Library/Logs/chi-service"
    if [ -n "${RESTIC_REPOSITORY:-}" ]; then
      install_job backup backup run "${BACKUP_HOUR:-4}" 17
    else
      remove_job backup
      warn "RESTIC_REPOSITORY 为空：不装每日备份"
    fi
    install_heartbeat
    case " $(resolve_stacks) " in
      *" media "*) install_job media-clean media clean 5 47; install_job media-iptv media iptv 5 27 ;;
      *) remove_job media-clean; remove_job media-iptv ;;
    esac
    [ -n "${RESTIC_REPOSITORY:-}" ] && log "手动触发备份测试：launchctl kickstart -k gui/$(id -u)/com.chi-service.backup"
    true
    ;;
  uninstall)
    remove_job backup; remove_job media-clean; remove_job media-iptv; remove_job heartbeat
    ok "已卸载全部定时任务"
    ;;
  *) die "用法: chi schedule [install|uninstall]" ;;
esac
