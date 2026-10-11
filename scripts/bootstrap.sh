#!/usr/bin/env bash
# Provision the machine. Every step is idempotent and can run on its own: chi bootstrap macos
# No arguments = all steps, in order.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
require_macos

STEPS_ALL="dotfiles brew macos runtime tailscale ollama"

step_dotfiles() {
  # Optional: apply your personal dotfiles with chezmoi (DOTFILES_REPO in .env, e.g. "github-user" or
  # "github-user/dotfiles"). Empty = skip. Already initialized = `chezmoi update`.
  if [ -z "${DOTFILES_REPO:-}" ]; then
    log "dotfiles: DOTFILES_REPO is empty, skipping"
    return 0
  fi
  ensure_brew_path
  have chezmoi || brew install chezmoi
  if [ -d "$(chezmoi source-path 2>/dev/null)" ]; then
    log "dotfiles: already initialized; running chezmoi update (preview with: chezmoi diff)"
    chezmoi update
    return 0
  fi
  log "dotfiles: first run on this machine; backing up shell/git configs that chezmoi may overwrite"
  local b f
  b="$HOME/.local/state/chi-dotfiles-backup/$(date +%F)"
  mkdir -p "$b"
  for f in .zshenv .zshrc .zprofile .gitconfig .tmux.conf; do
    if [ -e "$HOME/$f" ]; then cp -p "$HOME/$f" "$b/"; fi
  done
  cp -R "$HOME/.config/zsh" "$HOME/.config/git" "$HOME/.config/tmux" "$b/" 2>/dev/null || true
  ok "Backup: $b"
  chezmoi init --apply ${DOTFILES_BRANCH:+--branch "$DOTFILES_BRANCH"} "$DOTFILES_REPO"
}

step_brew() {
  log "Homebrew + Brewfile"
  if ! xcode-select -p >/dev/null 2>&1; then
    warn "Xcode Command Line Tools are required; an installer dialog will open. Re-run chi bootstrap afterwards"
    xcode-select --install || true
    exit 1
  fi
  if ! have brew && [ ! -x /opt/homebrew/bin/brew ]; then
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  fi
  ensure_brew_path
  brew bundle --file="$CHI_ROOT/Brewfile"
  ok "Homebrew packages installed"
}

step_macos() {
  "$CHI_ROOT/scripts/macos.sh"
}

step_runtime() {
  ensure_brew_path
  local rt="${CHI_RUNTIME:-orbstack}"
  log "Container runtime: $rt"
  case "$rt" in
    orbstack)
      brew list --cask orbstack >/dev/null 2>&1 || brew install --cask orbstack
      open -a OrbStack
      log "Waiting for OrbStack (the first launch asks you to accept its terms)"
      local i=0
      until docker_ready; do
        i=$((i + 1)); [ "$i" -gt 60 ] && die "OrbStack did not come up within 60s; open its window and check"
        sleep 1; ensure_brew_path
      done
      # Start at login. If OrbStack ever renames this key, tick "Start at login" in its settings instead.
      orb config set app.start_at_login true >/dev/null 2>&1 \
        || warn "Could not enable OrbStack start-at-login; enable it in OrbStack -> Settings -> Start at login"
      ;;
    colima)
      brew install colima docker docker-compose
      # Let the docker CLI find the Homebrew compose plugin
      mkdir -p "$HOME/.docker"
      local cfg="$HOME/.docker/config.json"
      [ -f "$cfg" ] || echo '{}' >"$cfg"
      jq '.cliPluginsExtraDirs = ["/opt/homebrew/lib/docker/cli-plugins"]' "$cfg" >"$cfg.tmp" && mv "$cfg.tmp" "$cfg"
      if ! colima status >/dev/null 2>&1; then
        # vz = Apple Virtualization.framework; virtiofs is the fastest shared-folder mode
        colima start --vm-type vz --mount-type virtiofs --cpu 4 --memory 8 --disk 100
      fi
      brew services start colima
      ;;
    *) die "CHI_RUNTIME must be orbstack or colima (got: $rt)" ;;
  esac
  docker_ready && ok "docker is up: $(docker version --format '{{.Server.Version}}')"
}

step_tailscale() {
  ensure_brew_path
  log "Tailscale (open-source tailscaled as a system daemon: online at boot, no login needed)"
  have tailscale || brew install tailscale
  if [ ! -f /Library/LaunchDaemons/com.tailscale.tailscaled.plist ]; then
    sudo tailscaled install-system-daemon
  fi
  sleep 2
  if ! tailscale status >/dev/null 2>&1; then
    log "Open the link below to log in to your Tailscale account"
    sudo_ts up --hostname="${CHI_HOSTNAME:-chi-mini}"
  fi
  ok "Tailscale is up: $(tailscale ip -4 2>/dev/null | head -n1)"
  warn "In https://login.tailscale.com/admin/machines, choose 'Disable key expiry' for this machine (otherwise it drops off after 180 days)"
  warn "In https://login.tailscale.com/admin/dns, enable MagicDNS and HTTPS Certificates (required by chi serve)"
  "$CHI_ROOT/scripts/init-env.sh" >/dev/null
}

step_ollama() {
  ensure_brew_path
  case " ${CHI_STACKS:-} " in
    *" ai "*) ;;
    *) log "'ai' is not in CHI_STACKS; skipping Ollama"; return 0 ;;
  esac
  log "Ollama (native, so it can use the Apple GPU / Metal; inside Docker it would be CPU-only)"
  have ollama || brew install ollama
  brew services start ollama
  ok "Ollama runs as a login service. Pull a model sized for your RAM: ollama pull <model> (see docs/modules/ai.md)"
}

# Make sure .env exists: later steps read CHI_RUNTIME / CHI_STACKS / CHI_HOSTNAME / DOTFILES_REPO
[ -f "$CHI_ROOT/.env" ] || "$CHI_ROOT/scripts/init-env.sh"
load_env

steps="${*:-$STEPS_ALL}"
for s in $steps; do
  case "$s" in
    dotfiles|brew|macos|runtime|tailscale|ollama) "step_$s" ;;
    *) die "Unknown step: ${s} (available: ${STEPS_ALL})" ;;
  esac
done

ok "bootstrap done: $steps"
log "Next: review .env -> bin/chi up -> bin/chi serve -> bin/chi doctor"
