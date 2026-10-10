#!/usr/bin/env bash
# 用 adb 远程管理 Google TV 盒子（或任何 Android 电视/投影）——不用拿遥控器一个个点。
#
# 先在盒子上：设置 → 系统 → 关于 → 连按「Android TV 操作系统版本/版本号」7 次开启开发者选项
#             → 开发者选项 → 打开「USB 调试」（部分机型叫「网络调试/无线调试」）
#
#   chi tv connect <ip>          连接盒子（第一次盒子上会弹窗，选“始终允许”）
#   chi tv install <apk>         安装 APK（侧载）
#   chi tv proxy <ip> on|off     把盒子的系统代理指向 Mac 上的 mihomo / 关闭
#   chi tv vpn <ip> <包名>|off   把某个 VPN App（如穿梭 com.fobwifi.transocks.tv）设为「始终开启」，开机自动连
#   chi tv apps                  列出已安装的第三方应用
#   chi tv shell                 进 adb shell
set -euo pipefail
. "$(dirname "$0")/lib.sh"
ensure_brew_path
[ -f "$CHI_ROOT/.env" ] && load_env
# adb 37 自带的 mDNS 设备发现在 macOS 27 上会让 adb server 崩溃（libunwind: invalid compact unwind encoding），
# 表现为每条命令都 “daemon not running; starting now”、连接一直 failed to authenticate。我们只用 IP 直连，关掉它
export ADB_MDNS=0

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
    # 先推到盒子上再本地装：Wi‑Fi 上直接 adb install 大文件常常中途 offline。
    # --bypass-low-target-sdk-block：Android 14 默认拒装面向老系统的 App（B 站云视听小电视就是）。
    # 后台跑 pm：Play 保护弹「已拦截不安全的应用」时 adb 会断，前台跑的安装会被一起杀掉 ——
    # 这时在电视上点「更多详情 → 仍然安装」
    adb push "$2" /data/local/tmp/chi-install.apk >/dev/null
    adb shell 'nohup pm install -r -g --bypass-low-target-sdk-block /data/local/tmp/chi-install.apk >/data/local/tmp/chi-install.log 2>&1 &'
    log "安装中…如果电视上弹 Play 保护，点「更多详情 → 仍然安装」"
    for _ in $(seq 1 30); do
      sleep 3
      r="$(adb shell cat /data/local/tmp/chi-install.log 2>/dev/null || true)"
      case "$r" in *Success*) ok "已安装 $2"; exit 0 ;; *Failure*|*Error*) die "安装失败：$r" ;; esac
    done
    die "90 秒还没装完：看看电视上是不是有 Play 保护弹窗"
    ;;
  vpn)
    t="$(target "${2:-}")"; adb connect "$t" >/dev/null
    case "${3:-}" in
      off) adb -s "$t" shell settings delete secure always_on_vpn_app >/dev/null; ok "已取消始终开启的 VPN" ;;
      "") die "用法: chi tv vpn <ip> <包名>|off（包名见 chi tv apps）" ;;
      *)
        # 不开 lockdown：VPN 挂了盒子照样能直连上网，只是大陆内容会提示地区限制
        adb -s "$t" shell "settings put secure always_on_vpn_app $3 && settings put secure always_on_vpn_lockdown 0"
        adb -s "$t" shell "dumpsys deviceidle whitelist +$3" >/dev/null
        ok "$3 设为始终开启：盒子重启后自动连接"
        ;;
    esac
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
