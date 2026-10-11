#!/usr/bin/env bash
# Manage a Google TV box (or any Android TV / projector) remotely over adb - no clicking through with the remote.
#
# On the box first: Settings -> System -> About -> press "Android TV OS build" 7 times to enable Developer options
#                   -> Developer options -> turn on "USB debugging" (some models: "Network/Wireless debugging")
#
#   chi tv connect <ip>          connect to the box (first time the box shows a prompt: pick "Always allow")
#   chi tv install <apk>         install (sideload) an APK
#   chi tv proxy <ip> on|off     point the box's system proxy at mihomo on the Mac / turn it off
#   chi tv vpn <ip> <pkg>|off    set a VPN app (e.g. com.fobwifi.transocks.tv) as always-on, connects at boot
#   chi tv apps                  list installed third-party apps
#   chi tv shell                 open an adb shell
set -euo pipefail
. "$(dirname "$0")/lib.sh"
ensure_brew_path
[ -f "$CHI_ROOT/.env" ] && load_env
# adb 37's built-in mDNS discovery crashes the adb server on macOS 27 (libunwind: invalid compact unwind encoding):
# every command prints "daemon not running; starting now" and connects keep failing to authenticate. We only connect
# by IP, so turn it off
export ADB_MDNS=0

if ! have adb; then
  is_macos || die "adb is required"
  log "Installing adb (android-platform-tools)"
  brew install --cask android-platform-tools
fi

target() {
  [ -n "${1:-}" ] || die "Give the box's IP (on the box: Settings -> Network -> current network)"
  case "$1" in *:*) echo "$1" ;; *) echo "$1:5555" ;; esac
}

mac_ip() { ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null; }

case "${1:-help}" in
  connect)
    adb connect "$(target "${2:-}")"
    adb devices
    ;;
  install)
    [ -f "${2:-}" ] || die "Usage: chi tv install <file.apk>"
    # Push to the box first, then install locally: a direct adb install of a big file over Wi-Fi often goes offline
    # midway. --bypass-low-target-sdk-block: Android 14 refuses apps targeting old SDKs by default (Bilibili's TV app
    # is one). Run pm in the background: when Play Protect shows "Blocked unsafe app" adb drops, and a foreground
    # install would be killed with it - then tap "More details -> Install anyway" on the TV
    adb push "$2" /data/local/tmp/chi-install.apk >/dev/null
    adb shell 'nohup pm install -r -g --bypass-low-target-sdk-block /data/local/tmp/chi-install.apk >/data/local/tmp/chi-install.log 2>&1 &'
    log "Installing... if Play Protect pops up on the TV, tap \"More details -> Install anyway\""
    for _ in $(seq 1 30); do
      sleep 3
      r="$(adb shell cat /data/local/tmp/chi-install.log 2>/dev/null || true)"
      case "$r" in *Success*) ok "Installed $2"; exit 0 ;; *Failure*|*Error*) die "Install failed: $r" ;; esac
    done
    die "Not installed after 90s: check the TV for a Play Protect prompt"
    ;;
  vpn)
    t="$(target "${2:-}")"; adb connect "$t" >/dev/null
    case "${3:-}" in
      off) adb -s "$t" shell settings delete secure always_on_vpn_app >/dev/null; ok "Always-on VPN cleared" ;;
      "") die "Usage: chi tv vpn <ip> <pkg>|off (package names: chi tv apps)" ;;
      *)
        # No lockdown: if the VPN dies the box still gets online directly; only mainland-only content shows a region error
        adb -s "$t" shell "settings put secure always_on_vpn_app $3 && settings put secure always_on_vpn_lockdown 0"
        adb -s "$t" shell "dumpsys deviceidle whitelist +$3" >/dev/null
        ok "$3 set as always-on: reconnects after the box reboots"
        ;;
    esac
    ;;
  proxy)
    t="$(target "${2:-}")"; adb connect "$t" >/dev/null
    case "${3:-}" in
      on)
        ip="$(mac_ip)"; [ -n "$ip" ] || die "Could not get the Mac's LAN IP"
        adb -s "$t" shell settings put global http_proxy "$ip:${CLASH_PORT:-7890}"
        ok "Box system proxy -> $ip:${CLASH_PORT:-7890} (only mainland sites go via China, the rest direct)"
        warn "If the Mac is off or mihomo dies, the box has no internet - then run chi tv proxy $2 off"
        ;;
      off)
        adb -s "$t" shell settings put global http_proxy :0
        ok "Box system proxy turned off"
        ;;
      *) die "Usage: chi tv proxy <ip> on|off" ;;
    esac
    ;;
  apps)  adb shell pm list packages -3 | sed 's/^package://' | sort ;;
  shell) adb shell ;;
  *) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//' ;;
esac
