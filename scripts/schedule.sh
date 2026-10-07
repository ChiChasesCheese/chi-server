#!/usr/bin/env bash
# 安装 launchd 定时任务（macOS 的 cron）。为什么不用 cron：cron 在 macOS 上是“遗留”的，
# 睡眠期间错过的任务不会补跑，权限（TCC）也更难管。launchd 是 Apple 的正路。
set -euo pipefail
. "$(dirname "$0")/lib.sh"
require_macos
load_env

AGENTS="$HOME/Library/LaunchAgents"
LABEL=com.chi-service.backup
DEST="$AGENTS/$LABEL.plist"

case "${1:-install}" in
  install)
    mkdir -p "$AGENTS" "$HOME/Library/Logs/chi-service"
    sed -e "s#__CHI_ROOT__#$CHI_ROOT#g" -e "s#__HOME__#$HOME#g" -e "s#__HOUR__#${BACKUP_HOUR:-4}#g" \
      "$CHI_ROOT/launchd/$LABEL.plist.tmpl" >"$DEST"
    plutil -lint "$DEST" >/dev/null
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$DEST"
    ok "每日 ${BACKUP_HOUR:-4}:17 自动备份。日志：~/Library/Logs/chi-service/backup.log"
    log "手动触发一次测试：launchctl kickstart -k gui/$(id -u)/$LABEL"
    ;;
  uninstall)
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    rm -f "$DEST"
    ok "已卸载 $LABEL"
    ;;
  *) die "用法: chi schedule [install|uninstall]" ;;
esac
