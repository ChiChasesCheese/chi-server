#!/usr/bin/env bash
# Make this machine run unattended: after a power loss or reboot, services come back with nobody present.
# Only does the steps that need a password (macOS requires one for these). Safe to re-run; finished steps are skipped.
#
#   1. Tailscale: make this user an operator and apply all chi serve rules (including the :8008 landing page)
#   2. FileVault: turn off (decrypts in the background; keep using the Mac meanwhile)
#   3. Auto-login: set to the current user once decryption is done
#
# Usage (must be a real terminal, it asks for passwords):
#   ssh -t chi-mini 'cd <repo> && bin/chi unattended'
# While FileVault is still decrypting, step 3 is skipped; run it again once decryption finishes.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
require_macos
ensure_brew_path
load_env

me="$(id -un)"
[ -t 0 ] || die "Needs an interactive terminal for passwords: ssh -t <host> 'cd ${CHI_ROOT} && bin/chi unattended'"

log "Step 1: Tailscale operator + serve rules (asks for your sudo password)"
sudo -v
sudo_ts set --operator="$me"
"$CHI_ROOT/scripts/tailscale-serve.sh" apply
ok "chi serve no longer needs sudo"

log "Step 2: FileVault"
fv="$(fdesetup status)"
case "$fv" in
  *"FileVault is Off"*)
    ok "FileVault is off" ;;
  *"Decryption in progress"*)
    ok "Decrypting: ${fv}" ;;
  *"FileVault is On"*)
    warn "Turning FileVault off (you'll be asked for a FileVault user and password: enter ${me} and your login password)"
    # fdesetup's exit code is unreliable on failure (prints "FileVault was not disabled (N)" yet may return 0); trust the status
    sudo fdesetup disable || true
    if fdesetup status | grep -qE "Off|Decryption in progress"; then
      ok "Decryption started; it runs in the background and the Mac stays usable"
    else
      warn "FileVault was not turned off (most likely a wrong user or password, or the account can't unlock FileVault)"
      warn "Alternative: System Settings -> Privacy & Security -> FileVault -> Turn Off"
    fi ;;
  *)
    warn "Unrecognized FileVault status: ${fv}; skipping" ;;
esac

log "Step 3: auto-login"
current="$(autologin_effective)"
if [ "$current" = "$me" ]; then
  ok "Auto-login already set: ${me}"
elif fdesetup status | grep -q "FileVault is Off"; then
  log "Setting auto-login to ${me} (enter ${me}'s login password below)"
  sudo sysadminctl -autologin set -userName "$me" -password - || true
  # With a wrong password sysadminctl may write autoLoginUser without storing the password; trust the real state
  if [ "$(autologin_effective)" = "$me" ]; then
    ok "Auto-login: ${me}"
  else
    warn "Auto-login did not take effect (most likely a wrong password). Set it by hand: System Settings -> Users & Groups -> Automatically log in as -> ${me}"
  fi
else
  warn "FileVault is still decrypting; auto-login can't be enabled yet. Run this again when it's done: bin/chi unattended"
  warn "Check progress: fdesetup status"
fi

log "Step 4: lock the screen right after auto-login (services keep running, the desktop needs a password)"
# Auto-login boots straight into an unlocked desktop; anyone at the machine, or connected with a tool that controls the
# main screen session (e.g. ToDesk), could use it. So: (a) require the password immediately after screensaver/display
# sleep; (b) 3 seconds after login start the screensaver + sleep the display = locked (locking doesn't stop login items
# or services from starting).
if sysadminctl -screenLock status 2>&1 | grep -q "immediate"; then
  ok "Password required immediately after display sleep/screensaver"
else
  log "Requiring the password immediately after display sleep/screensaver (enter ${me}'s login password below)"
  sysadminctl -screenLock immediate -password - \
    || warn "Didn't work; set it by hand: System Settings -> Lock Screen -> Require password after screen saver begins or display is turned off -> Immediately"
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
  <array><string>/bin/sh</string><string>-c</string><string>sleep 3; /usr/bin/open -a ScreenSaverEngine; /usr/bin/pmset displaysleepnow</string></array>
  <key>RunAtLoad</key><true/>
</dict>
</plist>
PLIST
plutil -lint "$agent" >/dev/null
launchctl bootout "gui/$(id -u)/com.chi-service.lock-at-login" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$agent" 2>/dev/null || true
ok "Screen locks 3 seconds after login (${agent})"

log "Result"
fdesetup status
echo "Auto-login (effective): $(autologin_effective)"
tailscale serve status 2>/dev/null | grep -E '^https' || true
