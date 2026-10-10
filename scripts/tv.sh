#!/usr/bin/env bash
# 用 adb 远程管理 Google TV 盒子（或任何 Android 电视/投影）——不用拿遥控器一个个点。
#
# 先在盒子上：设置 → 系统 → 关于 → 连按「Android TV 操作系统版本/版本号」7 次开启开发者选项
#             → 开发者选项 → 打开「USB 调试」（部分机型叫「网络调试/无线调试」）
#
#   chi tv connect <ip>          连接盒子（第一次盒子上会弹窗，选“始终允许”）
#   chi tv install <apk>         安装 APK（侧载）
#   chi tv proxy <ip> on|off     把盒子的系统代理指向 Mac 上的 mihomo / 关闭
#   chi tv apps                  列出已安装的第三方应用
#   chi tv shell                 进 adb shell
set -euo pipefail
. "$(dirname "$0")/lib.sh"
ensure_brew_path
[ -f "$CHI_ROOT/.env" ] && load_env

if ! have adb; then
  is_macos || die "需要 adb"
  log "安装 adb（android-platform-tools）"
  brew install --cask android-platform-tools
fi

target() {
  [ -n "${1:-}" ] || die "要给盒子的 IP（盒子：设置 → 网络 → 当前网络里能看到）"
  case "$1" in *:*) echo "$1" ;; *) echo "$1:5555" ;; esac
}

mac_ip() { ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null; }

case "${1:-help}" in
  connect)
    adb connect "$(target "${2:-}")"
    adb devices
    ;;
  install)
    [ -f "${2:-}" ] || die "用法: chi tv install <文件.apk>"
    adb install -r "$2" && ok "已安装 $2"
    ;;
  proxy)
    t="$(target "${2:-}")"; adb connect "$t" >/dev/null
    case "${3:-}" in
      on)
        ip="$(mac_ip)"; [ -n "$ip" ] || die "取不到 Mac 的局域网 IP"
        adb -s "$t" shell settings put global http_proxy "$ip:${CLASH_PORT:-7890}"
        ok "盒子系统代理 → $ip:${CLASH_PORT:-7890}（只有大陆站点走回国，其他直连）"
        warn "Mac 关机或 mihomo 挂了，盒子就上不了网 —— 到时 chi tv proxy $2 off"
        ;;
      off)
        adb -s "$t" shell settings put global http_proxy :0
        ok "已关闭盒子的系统代理"
        ;;
      *) die "用法: chi tv proxy <ip> on|off" ;;
    esac
    ;;
  apps)  adb shell pm list packages -3 | sed 's/^package://' | sort ;;
  shell) adb shell ;;
  *) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//' ;;
esac
