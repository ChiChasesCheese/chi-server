#!/usr/bin/env bash
# macOS 当服务器用的系统设置。需要 sudo。幂等。
# 每一项都写了“为什么”，不认同的话注释掉那一行就行。
set -euo pipefail
. "$(dirname "$0")/lib.sh"
require_macos
[ -f "$CHI_ROOT/.env" ] && load_env

log "macOS 服务器设置（会要 sudo 密码）"
sudo -v

# ---------- 电源 ----------
# sleep 0        永不睡眠（服务器睡了就是宕机）
# disksleep 0    硬盘不休眠（外接盘也别停转，否则访问时卡几秒）
# displaysleep 10 显示器可以睡，不影响服务
# powernap 0     服务器不需要 Power Nap，它会造成奇怪的半睡半醒状态
# womp 1         允许网络唤醒（Wake on LAN）
# autorestart 1  断电恢复后自动开机 ← 最重要的一项
# tcpkeepalive 1 保持 TCP 连接
sudo pmset -a sleep 0 disksleep 0 displaysleep 10 powernap 0 womp 1 autorestart 1 tcpkeepalive 1
ok "pmset 已设置：永不睡眠 / 断电自动开机 / 网络唤醒"

# 系统死机时自动重启。新版 macOS 里 systemsetup 某些子命令需要“完全磁盘访问”权限，失败就跳过
sudo systemsetup -setrestartfreeze on >/dev/null 2>&1 && ok "死机自动重启已开" \
  || warn "systemsetup 需要终端有“完全磁盘访问权限”，跳过 restartfreeze（不影响主要功能）"

# ---------- 主机名 ----------
if [ -n "${CHI_HOSTNAME:-}" ]; then
  if [ "$(scutil --get LocalHostName 2>/dev/null || true)" != "$CHI_HOSTNAME" ]; then
    sudo scutil --set ComputerName "$CHI_HOSTNAME"
    sudo scutil --set HostName "$CHI_HOSTNAME"
    sudo scutil --set LocalHostName "$CHI_HOSTNAME"
    ok "主机名 → $CHI_HOSTNAME（局域网可用 $CHI_HOSTNAME.local）"
  fi
fi

# ---------- 防火墙 ----------
# 开启应用防火墙 + 隐身模式（不回 ping / 不响应端口探测）。
# allowsigned / allowsignedapp：自动放行 Apple 自带和有开发者签名的 App（OrbStack、Tailscale 都是），
# 否则 OrbStack 转发的端口会被拦，局域网访问不了。
FW=/usr/libexec/ApplicationFirewall/socketfilterfw
sudo "$FW" --setglobalstate on >/dev/null
sudo "$FW" --setstealthmode on >/dev/null
sudo "$FW" --setallowsigned on >/dev/null
sudo "$FW" --setallowsignedapp on >/dev/null
ok "防火墙：开启 + 隐身模式 + 放行已签名应用"

# ---------- SSH（远程登录） ----------
if ! nc -z 127.0.0.1 22 >/dev/null 2>&1; then
  if sudo systemsetup -setremotelogin on >/dev/null 2>&1; then
    ok "远程登录（SSH）已开启"
  else
    warn "命令行开不了 SSH（需要完全磁盘访问权限）。手动开：系统设置 → 通用 → 共享 → 远程登录"
  fi
else
  ok "SSH 已在监听"
fi

# 只允许密钥登录 —— 前提是你已经放了公钥，否则会把自己锁在外面，所以这里有保护。
# 默认不开（CHI_SSH_KEY_ONLY=1 才开），原因见 docs/macos-setup.md「FileVault 与 SSH 解锁」：
# macOS 26 的 FileVault 预启动 SSH 解锁要用密码，我没法确认关掉密码登录是否影响它，你要自己验证一次。
DROPIN=/etc/ssh/sshd_config.d/000-chi.conf
if [ "${CHI_SSH_KEY_ONLY:-0}" = "1" ]; then
  if [ -s "$HOME/.ssh/authorized_keys" ]; then
    sudo tee "$DROPIN" >/dev/null <<'EOF'
# 由 chi-service scripts/macos.sh 生成。sshd 取“第一次出现”的值，所以文件名用 000 排在最前。
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
EOF
    sudo sshd -t && ok "SSH 已改为仅密钥登录（$DROPIN）"
  else
    warn "$HOME/.ssh/authorized_keys 是空的，不开仅密钥登录（会把自己锁外面）。先从你的电脑 ssh-copy-id"
  fi
fi

# ---------- 系统更新 ----------
# 自动检查、自动下载、自动装安全补丁（Rapid Security Response / XProtect），
# 但 *不* 自动装 macOS 大版本/小版本 —— 那会重启，开了 FileVault 的话会卡在解锁界面。
SU=/Library/Preferences/com.apple.SoftwareUpdate
sudo defaults write "$SU" AutomaticCheckEnabled -bool true
sudo defaults write "$SU" AutomaticDownload -bool true
sudo defaults write "$SU" CriticalUpdateInstall -bool true
sudo defaults write "$SU" ConfigDataInstall -bool true
sudo defaults write /Library/Preferences/com.apple.commerce AutoUpdateRestartRequired -bool false
ok "系统更新：自动下载 + 自动装安全补丁，系统升级手动做（chi 文档里有带 FileVault 的重启方法）"

# ---------- 状态汇报（不改，只提示） ----------
fv="$(fdesetup status 2>/dev/null || true)"
log "FileVault: $fv"
case "$fv" in
  *"On"*) warn "FileVault 开着：断电重启后要先解锁才能跑服务。读 docs/macos-setup.md 选一个模式" ;;
esac

ok "macOS 设置完成。剩下几项必须在 系统设置 里手点，清单见 docs/macos-setup.md"
