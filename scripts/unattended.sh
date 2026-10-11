#!/usr/bin/env bash
# 让这台机器“无人值守”：断电/重启后不用任何人到场，服务自己回来。
# 只做必须输密码的那几步（macOS 规定这些不能免密），可重复执行，已完成的步骤会跳过。
#
#   1. Tailscale：把本用户设为 operator，并挂上 chi serve 的全部规则（含 :8008 接入页）
#   2. FileVault：关闭（后台解密，可照常使用）
#   3. 自动登录：解密完成后设为当前用户
#
# 用法（必须在真终端里，要输密码）：
#   ssh -t chi-mini 'cd ~/chi-service && bin/chi unattended'
# FileVault 还在解密时第 3 步会跳过，等解密完再跑一次即可。
set -euo pipefail
. "$(dirname "$0")/lib.sh"
require_macos
ensure_brew_path
load_env

me="$(id -un)"
[ -t 0 ] || die "需要交互终端输密码：ssh -t chi-mini 'cd ~/chi-service && bin/chi unattended'"

log "第 1 步：Tailscale operator + serve 规则（会要 sudo 密码）"
sudo -v
sudo_ts set --operator="$me"
"$CHI_ROOT/scripts/tailscale-serve.sh" apply
ok "以后 chi serve 不再需要 sudo"

log "第 2 步：FileVault"
fv="$(fdesetup status)"
case "$fv" in
  *"FileVault is Off"*)
    ok "FileVault 已关闭" ;;
  *"Decryption in progress"*)
    ok "正在解密中：${fv}" ;;
  *"FileVault is On"*)
    warn "即将关闭 FileVault（下面会问 FileVault 用户名和密码，填 ${me} 和登录密码）"
    # fdesetup 失败时退出码不可靠（会打印 "FileVault was not disabled (N)" 但仍可能返回 0），以状态为准
    sudo fdesetup disable || true
    if fdesetup status | grep -qE "Off|Decryption in progress"; then
      ok "已开始解密，后台进行，期间可照常使用"
    else
      warn "FileVault 没有关掉（多半是用户名或密码不对，或该账号不是 FileVault 解锁用户）"
      warn "可改用：系统设置 → 隐私与安全性 → FileVault → 关闭"
    fi ;;
  *)
    warn "看不懂的 FileVault 状态：${fv}，跳过" ;;
esac

log "第 3 步：自动登录"
current="$(defaults read /Library/Preferences/com.apple.loginwindow autoLoginUser 2>/dev/null || true)"
if [ "$current" = "$me" ]; then
  ok "已设置自动登录：${me}"
elif fdesetup status | grep -q "FileVault is Off"; then
  log "设置自动登录为 ${me}（下面输 ${me} 的登录密码）"
  if sudo sysadminctl -autologin set -userName "$me" -password -; then
    ok "自动登录：${me}"
  else
    warn "命令行设置失败，请手动：系统设置 → 用户与群组 → 自动登录 → ${me}"
  fi
else
  warn "FileVault 还没解密完，暂时不能开自动登录。解密完成后再跑一次：bin/chi unattended"
  warn "看进度：fdesetup status"
fi

log "第 4 步：自动登录后立刻锁屏（服务照跑，桌面要密码）"
# 自动登录 = 开机直接进已解锁的桌面；任何站在机器前、或用 ToDesk 这类“控制主屏幕会话”的工具连上来的人都能直接用。
# 所以：(a) 屏保/熄屏后立即要密码；(b) 登录 60 秒后（等 OrbStack 等登录项起来）自动启动屏保 = 锁屏。
if sysadminctl -screenLock status 2>&1 | grep -q "immediate"; then
  ok "熄屏/屏保后立即要求密码"
else
  log "设置熄屏/屏保后立即要求密码（下面输 ${me} 的登录密码）"
  sysadminctl -screenLock immediate -password - \
    || warn "没设成功，请手动：系统设置 → 锁定屏幕 → 屏幕保护程序启动或显示器关闭后要求输入密码 → 立即"
fi
agent="$HOME/Library/LaunchAgents/com.chi-service.lock-at-login.plist"
mkdir -p "$HOME/Library/LaunchAgents"
cat >"$agent" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.chi-service.lock-at-login</string>
  <key>ProgramArguments</key>
  <array><string>/bin/sh</string><string>-c</string><string>sleep 60; /usr/bin/open -a ScreenSaverEngine</string></array>
  <key>RunAtLoad</key><true/>
</dict>
</plist>
PLIST
plutil -lint "$agent" >/dev/null
launchctl bootout "gui/$(id -u)/com.chi-service.lock-at-login" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$agent" 2>/dev/null || true
ok "登录 60 秒后自动锁屏（${agent}）"

log "结果"
fdesetup status
echo "autoLoginUser: $(defaults read /Library/Preferences/com.apple.loginwindow autoLoginUser 2>/dev/null || echo 无)"
tailscale serve status 2>/dev/null | grep -E '^https' || true
