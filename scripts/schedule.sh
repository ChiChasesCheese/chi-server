#!/usr/bin/env bash
# 安装 launchd 定时任务（macOS 的 cron）。为什么不用 cron：cron 在 macOS 上是“遗留”的，
# 睡眠期间错过的任务不会补跑，权限（TCC）也更难管。launchd 是 Apple 的正路。
#
# 任务：
#   backup       每天 BACKUP_HOUR:17   chi backup run
#   media-clean  每天 05:47            chi media clean（只在启用了 media stack 时安装）
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

case "${1:-install}" in
  install)
    mkdir -p "$AGENTS" "$HOME/Library/Logs/chi-service"
    install_job backup backup run "${BACKUP_HOUR:-4}" 17
    case " $(resolve_stacks) " in
      *" media "*) install_job media-clean media clean 5 47 ;;
      *) remove_job media-clean ;;
    esac
    log "手动触发测试：launchctl kickstart -k gui/$(id -u)/com.chi-service.backup"
    ;;
  uninstall)
    remove_job backup; remove_job media-clean
    ok "已卸载全部定时任务"
    ;;
  *) die "用法: chi schedule [install|uninstall]" ;;
esac
