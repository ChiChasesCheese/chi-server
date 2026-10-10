#!/usr/bin/env bash
# 装机。每一步都幂等，可以单独跑：chi bootstrap macos
# 不带参数 = 按顺序全跑。
set -euo pipefail
. "$(dirname "$0")/lib.sh"
require_macos

STEPS_ALL="dotfiles brew macos runtime tailscale ollama"

step_dotfiles() {
  # 个人开发环境交给 chifig（chezmoi 管的 zsh / git / ghostty / tmux / 键盘映射…），这里只负责调用它。
  # 已经装过（有 chezmoi 源目录）就只做 chezmoi update。
  if command -v chezmoi >/dev/null 2>&1 && [ -d "$(chezmoi source-path 2>/dev/null)" ]; then
    log "chifig 已安装：chezmoi update（先看差异：chezmoi diff）"
    chezmoi update
    return 0
  fi
  log "chifig：第一次接管这台机器，先备份会被覆盖的 shell / git 配置"
  local b
  b="$HOME/.local/state/chifig-backup/$(date +%F)"
  mkdir -p "$b"
  local f
  for f in .zshenv .zshrc .zprofile .gitconfig .tmux.conf .condarc; do
    if [ -e "$HOME/$f" ]; then cp -p "$HOME/$f" "$b/"; fi
  done
  cp -R "$HOME/.config/zsh" "$HOME/.config/git" "$HOME/.config/tmux" "$HOME/.config/ghostty" "$b/" 2>/dev/null || true
  ok "备份在 $b"
  log "安装 chifig（会问 git 身份和模块开关；Windows 键盘想要 Alt→Cmd / Win→Ctrl 就把 modules.keyboard 选 true）"
  CHIFIG_REF="${CHIFIG_REF:-main}" \
    sh -c "$(curl -fsSL "https://raw.githubusercontent.com/ChiChasesCheese/chifig/${CHIFIG_REF:-main}/bootstrap.sh")"
}

step_brew() {
  log "Homebrew + Brewfile"
  if ! xcode-select -p >/dev/null 2>&1; then
    warn "需要 Xcode Command Line Tools，会弹窗安装；装完重新跑 chi bootstrap"
    xcode-select --install || true
    exit 1
  fi
  if ! have brew && [ ! -x /opt/homebrew/bin/brew ]; then
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  fi
  ensure_brew_path
  brew bundle --file="$CHI_ROOT/Brewfile"
  ok "brew 包已安装"
}

step_macos() {
  "$CHI_ROOT/scripts/macos.sh"
}

step_runtime() {
  ensure_brew_path
  local rt="${CHI_RUNTIME:-orbstack}"
  log "容器运行时：$rt"
  case "$rt" in
    orbstack)
      brew list --cask orbstack >/dev/null 2>&1 || brew install --cask orbstack
      open -a OrbStack
      log "等 OrbStack 起来（第一次会弹窗让你同意条款，点一下）"
      local i=0
      until docker_ready; do
        i=$((i + 1)); [ "$i" -gt 60 ] && die "OrbStack 60 秒没起来，打开它的窗口看看"
        sleep 1; ensure_brew_path
      done
      # 开机（登录后）自动启动。这个键名如果哪天 OrbStack 改了，就去它设置里手动勾 "Start at login"
      orb config set app.start_at_login true >/dev/null 2>&1 \
        || warn "没能自动开启 OrbStack 开机自启，去 OrbStack → Settings → 勾选 Start at login"
      ;;
    colima)
      brew install colima docker docker-compose
      # 让 docker CLI 找到 brew 装的 compose 插件
      mkdir -p "$HOME/.docker"
      local cfg="$HOME/.docker/config.json"
      [ -f "$cfg" ] || echo '{}' >"$cfg"
      jq '.cliPluginsExtraDirs = ["/opt/homebrew/lib/docker/cli-plugins"]' "$cfg" >"$cfg.tmp" && mv "$cfg.tmp" "$cfg"
      if ! colima status >/dev/null 2>&1; then
        # vz = Apple Virtualization.framework，virtiofs 共享目录最快
        colima start --vm-type vz --mount-type virtiofs --cpu 4 --memory 8 --disk 100
      fi
      brew services start colima
      ;;
    *) die "CHI_RUNTIME 只能是 orbstack 或 colima，当前：$rt" ;;
  esac
  docker_ready && ok "docker 可用：$(docker version --format '{{.Server.Version}}')"
}

step_tailscale() {
  ensure_brew_path
  log "Tailscale（开源 tailscaled，作为系统守护进程：开机即上线，不用等人登录）"
  have tailscale || brew install tailscale
  if [ ! -f /Library/LaunchDaemons/com.tailscale.tailscaled.plist ]; then
    sudo tailscaled install-system-daemon
  fi
  sleep 2
  if ! tailscale status >/dev/null 2>&1; then
    log "打开下面的链接登录你的 Tailscale 账号"
    sudo_ts up --hostname="${CHI_HOSTNAME:-chi-mini}"
  fi
  ok "Tailscale 已上线：$(tailscale ip -4 2>/dev/null | head -n1)"
  warn "去 https://login.tailscale.com/admin/machines 对这台机器点 'Disable key expiry'，否则 180 天后掉线"
  warn "去 https://login.tailscale.com/admin/dns 打开 MagicDNS 和 HTTPS Certificates（chi serve 需要）"
  "$CHI_ROOT/scripts/init-env.sh" >/dev/null
}

step_ollama() {
  ensure_brew_path
  case " ${CHI_STACKS:-} " in
    *" ai "*) ;;
    *) log "CHI_STACKS 里没有 ai，跳过 Ollama"; return 0 ;;
  esac
  log "Ollama（原生跑，才能用 Apple GPU / Metal；Docker 里只能用 CPU）"
  have ollama || brew install ollama
  brew services start ollama
  ok "Ollama 已作为登录项服务启动。拉模型：ollama pull qwen3:8b（按内存挑，见 docs/services.md）"
}

# 先确保 .env 存在，后面的步骤要读 CHI_RUNTIME / CHI_STACKS / CHI_HOSTNAME
[ -f "$CHI_ROOT/.env" ] || "$CHI_ROOT/scripts/init-env.sh"
load_env

steps="${*:-$STEPS_ALL}"
for s in $steps; do
  case "$s" in
    dotfiles|brew|macos|runtime|tailscale|ollama) "step_$s" ;;
    *) die "未知步骤：${s}（可选：${STEPS_ALL}）" ;;
  esac
done

ok "bootstrap 完成：$steps"
log "下一步：检查 .env → bin/chi up → bin/chi serve → bin/chi doctor"
