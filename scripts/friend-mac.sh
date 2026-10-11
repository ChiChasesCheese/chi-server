#!/usr/bin/env bash
# Let a friend use this Mac remotely via Screen Sharing, with their own macOS account (alongside you, independently).
#
# Usage (run as your own admin account, without sudo; the script asks for your sudo password when needed):
#   scripts/friend-mac.sh add <username> [full name] [--ssh]   create account / set password, tighten permissions, allow Screen Sharing
#   scripts/friend-mac.sh status                                show current state (no root needed)
#   scripts/friend-mac.sh remove <username> [--delete]          revoke access; --delete also deletes the account and its home folder
#
# Background (details in docs/guest-access.md):
# - Screen Sharing's "Only these users" = local group com.apple.access_screensharing (a SACL);
#   Remote Login (SSH)'s "Only these users" = com.apple.access_ssh, checked by sshd's PAM module pam_sacl.
#   Choosing "All users" in System Settings renames the group to xxx-disabled to switch it off; this script follows the same convention.
# - Since macOS 12.1 Apple no longer allows turning on Screen Sharing with kickstart. We use launchctl enable + bootstrap,
#   which is unofficial; if it fails we print the System Settings click path instead.
# - "VNC viewers may control screen with password" (VNCLegacyConnectionsEnabled) must be off: it is one weak password
#   shared by everyone, bypasses user accounts, and can't "log in as yourself".
set -euo pipefail
. "$(dirname "$0")/lib.sh"
require_macos

SS_GROUP=com.apple.access_screensharing
SSH_GROUP=com.apple.access_ssh
SS_PLIST=/System/Library/LaunchDaemons/com.apple.screensharing.plist
RM_PREFS=/Library/Preferences/com.apple.RemoteManagement
VNC_PW_FILE=/Library/Preferences/com.apple.VNCSettings.txt
# The machine's Tailscale name comes from .env (TS_FQDN, set by chi init); the repo is public, so never hardcode a real tailnet name here
if [ -f "$CHI_ROOT/.env" ]; then load_env; fi
HOST_FQDN="${TS_FQDN:-<your-machine>.<your-tailnet>.ts.net}"
OWNER="$(id -un)"

usage() {
  sed -n '4,7p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-1}"
}

# ---------- Small helpers (none need root) ----------
user_exists()  { dscl . -read "/Users/$1" UniqueID >/dev/null 2>&1; }
group_exists() { dscl . -read "/Groups/$1" PrimaryGroupID >/dev/null 2>&1; }
is_member()    { dseditgroup -o checkmember -m "$1" "$2" >/dev/null 2>&1; }
is_admin()     { is_member "$1" admin; }
# Accounts created with sysadminctl -addUser without -password have no AuthenticationAuthority and can't log in
has_password() { dscl . -read "/Users/$1" AuthenticationAuthority >/dev/null 2>&1; }
user_home()    { dscl . -read "/Users/$1" NFSHomeDirectory 2>/dev/null | awk '{print $2}'; }
# A one-word value sits on the same line as the key; a value with spaces wraps to the next line. Handle both
real_name()    { dscl . -read "/Users/$1" RealName 2>/dev/null | sed -e '1s/^RealName:[[:space:]]*//' -e 's/^[[:space:]]*//' | tr -d '\n'; }
user_uid()     { dscl . -read "/Users/$1" UniqueID 2>/dev/null | awk '{print $2}'; }
port_listening() { netstat -an -p tcp 2>/dev/null | grep -Eq "[.:]$1 .*LISTEN"; }
vnc_legacy_on() { [ "$(defaults read "$RM_PREFS" VNCLegacyConnectionsEnabled 2>/dev/null || echo 0)" = "1" ]; }
ss_enabled_in_launchd() { launchctl print-disabled system 2>/dev/null | grep -q '"com.apple.screensharing" => enabled'; }
ss_loaded() { launchctl print system/com.apple.screensharing >/dev/null 2>&1; }
# Users with a GUI session (including background sessions opened by Screen Sharing)
gui_users() { ps -axo user=,comm= 2>/dev/null | awk '$2 ~ /loginwindow$/ {print $1}' | sort -u; }

valid_username() {
  case "$1" in
    ''|*[!a-z0-9_.-]*|[!a-z_]*) return 1 ;;
  esac
  [ "${#1}" -le 31 ]
}

# Group members: direct members + nested groups (resolved to group names)
group_members() {
  local g="$1" members nested guid name
  members="$(dscl . -read "/Groups/$g" GroupMembership 2>/dev/null | sed 's/^GroupMembership://' | xargs || true)"
  nested=""
  for guid in $(dscl . -read "/Groups/$g" NestedGroups 2>/dev/null | sed 's/^NestedGroups://'); do
    name="$(dscl . -search /Groups GeneratedUID "$guid" 2>/dev/null | awk 'NR==1{print $1}')"
    nested="$nested ${name:-$guid}(group)"
  done
  printf '%s%s\n' "${members:-(no direct members)}" "$nested"
}

# Make sure the SACL group is active: leave it alone if it exists; if xxx-disabled exists, rename it back (keeping its
# nested admin group, same as picking "Only these users" in System Settings); otherwise create it. Then always add
# the admin running this, so you never lock yourself out.
ensure_sacl_group() {
  local g="$1" desc="$2"
  if group_exists "$g"; then
    :
  elif group_exists "$g-disabled"; then
    log "Enabling ${g} (renaming ${g}-disabled back, same as \"Only these users\" in System Settings)"
    sudo dscl . -change "/Groups/$g-disabled" RecordName "$g-disabled" "$g"
  else
    log "Creating $g"
    sudo dseditgroup -o create -r "$desc" -q "$g"
  fi
  if ! is_member "$OWNER" "$g"; then
    sudo dseditgroup -o edit -a "$OWNER" -t user "$g"
  fi
}

group_add() {
  local u="$1" g="$2"
  if is_member "$u" "$g"; then
    ok "$u is already in $g"
  else
    sudo dseditgroup -o edit -a "$u" -t user "$g"
    ok "$u -> $g"
  fi
}

group_del() {
  local u="$1" g="$2"
  group_exists "$g" || return 0
  # checkmember also counts nested groups, so look at direct members only
  if dscl . -read "/Groups/$g" GroupMembership 2>/dev/null | tr ' ' '\n' | grep -qx "$u"; then
    sudo dseditgroup -o edit -d "$u" -t user "$g"
    ok "$u removed from $g"
  fi
}

print_click_path() {
  cat <<EOF
  Turn it on by hand: System Settings -> General -> Sharing -> switch on "Screen Sharing" -> click its (i):
    - "VNC viewers may control screen with password": off
    - "Allow access for": "Only these users", with yourself (or "Administrators") and your friend listed
  (Turn off "Remote Management" first - it can't run alongside Screen Sharing.)
EOF
}

ensure_screen_sharing_on() {
  if port_listening 5900; then
    ok "Screen Sharing is on (listening on 5900)"
    return 0
  fi
  if pgrep -x ARDAgent >/dev/null 2>&1; then
    warn "Remote Management (ARD) seems to be on; it conflicts with Screen Sharing. Turn it off in System Settings -> General -> Sharing"
  fi
  log "Trying to turn on Screen Sharing via launchctl (unofficial; Apple only documents that kickstart stopped working in 12.1)"
  sudo launchctl enable system/com.apple.screensharing || true
  ss_loaded || sudo launchctl bootstrap system "$SS_PLIST" 2>/dev/null || true
  local i=0
  while [ $i -lt 5 ] && ! port_listening 5900; do
    sleep 1; i=$((i + 1))
  done
  if port_listening 5900; then
    ok "Screen Sharing is on (listening on 5900). Double-check that the switch in System Settings agrees"
  else
    warn "Could not turn on Screen Sharing from the command line"
    print_click_path
  fi
}

ensure_vnc_password_off() {
  if vnc_legacy_on || sudo test -f "$VNC_PW_FILE"; then
    log "Turning off \"VNC viewers may control screen with password\""
    sudo defaults write "$RM_PREFS" VNCLegacyConnectionsEnabled -bool false
    sudo rm -f "$VNC_PW_FILE"
    ok "Shared VNC password turned off and deleted"
  else
    ok "Shared VNC password is off"
  fi
}

# ---------- add ----------
cmd_add() {
  local user="" full="" want_ssh=0 arg
  for arg in "$@"; do
    case "$arg" in
      --ssh) want_ssh=1 ;;
      -h|--help) usage 0 ;;
      -*) die "Unknown option: $arg" ;;
      *) if [ -z "$user" ]; then user="$arg"; elif [ -z "$full" ]; then full="$arg"; else die "Too many arguments: $arg"; fi ;;
    esac
  done
  [ -n "$user" ] || usage
  valid_username "$user" || die "Username may only use lowercase letters, digits and _.- and must start with a letter or _: $user"
  [ "$user" != "$OWNER" ] && [ "$user" != root ] || die "Refusing to do this for $user"
  [ "$(id -u)" -ne 0 ] || die "Don't run this with sudo; run it as your own admin account (it asks for your sudo password when needed)"
  is_admin "$OWNER" || die "$OWNER is not an admin and can't change these settings"

  log "Setting up Screen Sharing for $user (needs your sudo password)"
  sudo -v

  # 1) Account + password
  if ! user_exists "$user"; then
    log "Creating standard user ${user} (you will be asked for their login password)"
    sudo sysadminctl -addUser "$user" -fullName "${full:-$user}" -password -
    user_exists "$user" || die "Failed to create $user"
    ok "Created $user"
  else
    ok "$user already exists (UID $(user_uid "$user"))"
    if [ -n "$full" ]; then
      sudo dscl . -create "/Users/$user" RealName "$full"   # -create overwrites the old value
    fi
  fi
  is_admin "$user" && die "$user is an admin. Guest accounts must be standard users: untick \"Allow this user to administer this computer\" in System Settings -> Users & Groups, then run again"

  if has_password "$user"; then
    ok "$user already has a password (to change it: sudo sysadminctl -resetPasswordFor $user -newPassword - -adminUser $OWNER -adminPassword -)"
  else
    log "$user has no password yet; setting one now (you will be asked for it)"
    # sysadminctl often exits 0 even on failure, so trust whether AuthenticationAuthority appeared
    sudo sysadminctl -resetPasswordFor "$user" -newPassword - || true
    if ! has_password "$user"; then
      # With FileVault on, this needs admin credentials ("not permitted without secure token unlock")
      warn "Retrying with your (${OWNER}) admin credentials: enter their new password first, then your own login password"
      sudo sysadminctl -resetPasswordFor "$user" -newPassword - -adminUser "$OWNER" -adminPassword - || true
    fi
    if ! has_password "$user"; then
      warn "sysadminctl did not set it; trying again with dscl"
      sudo dscl . -passwd "/Users/$user"
    fi
    has_password "$user" || die "Still no password for ${user}; set one in System Settings -> Users & Groups"
    ok "Password set for $user"
  fi

  # 2) Home folders private to their owner (macOS defaults to 750, so anyone in group staff can list them)
  local home u
  for u in "$OWNER" "$user"; do
    home="$(user_home "$u")"
    if [ -n "$home" ] && [ -d "$home" ]; then
      if [ "$(stat -f '%Lp' "$home")" != "700" ]; then
        sudo chmod 700 "$home"
        ok "$home -> 700"
      else
        ok "$home is already 700"
      fi
    else
      warn "Home folder ${home:-?} for $u doesn't exist yet (created on first login); run this again after they log in once"
    fi
  done

  # 3) Screen Sharing allow list
  ensure_sacl_group "$SS_GROUP" "Screensharing Service ACL"
  group_add "$user" "$SS_GROUP"

  # 4) SSH allow list: admins only by default; guests only with --ssh
  ensure_sacl_group "$SSH_GROUP" "SSH Service ACL"
  if [ "$want_ssh" = 1 ]; then
    group_add "$user" "$SSH_GROUP"
  else
    group_del "$user" "$SSH_GROUP"
    ok "SSH is limited to $SSH_GROUP (admins + ${OWNER}); $user can't SSH (re-run with --ssh to allow)"
  fi

  # 5) Shared VNC password off, Screen Sharing on
  ensure_vnc_password_off
  ensure_screen_sharing_on

  echo
  ok "Done. Your friend connects like this (they need to be on Tailscale first):"
  cat <<EOF
  On their Mac: open the Screen Sharing app (or Finder -> Go -> Connect to Server) -> vnc://$HOST_FQDN
         -> username $user + their password -> if told someone is using it, choose "Log in as yourself"
  After first login: signing into an Apple Account is fine, but keep "Find My Mac" off (it would activation-lock this machine)
EOF
  warn "Double-check System Settings -> General -> Sharing -> Screen Sharing (i): VNC password off, Only these users"
}

# ---------- remove ----------
cmd_remove() {
  local user="" del=0 arg
  for arg in "$@"; do
    case "$arg" in
      --delete) del=1 ;;
      -h|--help) usage 0 ;;
      -*) die "Unknown option: $arg" ;;
      *) [ -z "$user" ] || die "Too many arguments: $arg"; user="$arg" ;;
    esac
  done
  [ -n "$user" ] || usage
  [ "$user" != "$OWNER" ] && [ "$user" != root ] || die "Refusing to do this for $user"
  [ "$(id -u)" -ne 0 ] || die "Don't run this with sudo"
  user_exists "$user" || die "No such user: $user"
  is_admin "$user" && die "$user is an admin; this script doesn't touch admin accounts"

  sudo -v
  group_del "$user" "$SS_GROUP"
  group_del "$user" "$SSH_GROUP"

  if gui_users | grep -qx "$user"; then
    warn "$user still has a session open. Revoking access doesn't disconnect them; to kick them out now:"
    echo "  sudo launchctl bootout gui/$(user_uid "$user")"
  fi

  if [ "$del" = 1 ]; then
    local ans=""
    printf 'About to delete account %s and its home folder %s (cannot be undone). Type the username to confirm: ' "$user" "$(user_home "$user")"
    read -r ans
    [ "$ans" = "$user" ] || die "Not confirmed, cancelled"
    sudo sysadminctl -deleteUser "$user" || true
    if user_exists "$user"; then
      # With FileVault on this fails with "not permitted without secure token unlock"; retry with admin credentials
      warn "Retrying with your (${OWNER}) admin credentials; you will be asked for your login password"
      sudo sysadminctl -deleteUser "$user" -adminUser "$OWNER" -adminPassword - || true
    fi
    if user_exists "$user"; then
      die "Delete failed (if they are still logged in, end their session and try again)"
    fi
    ok "Deleted account $user"
  else
    ok "$user can no longer log in via Screen Sharing / SSH (the account still exists; add --delete to remove it)"
  fi
}

# ---------- status ----------
cmd_status() {
  local u uid home perm flags
  log "Local users (UID >= 500)"
  printf '  %-12s %-5s %-6s %-6s %-11s %s\n' USER UID ADMIN PASSWD HOME_PERMS NAME
  dscl . -list /Users UniqueID | awk '$2 >= 500 {print $1, $2}' | while read -r u uid; do
    home="$(user_home "$u")"
    perm="$( [ -d "$home" ] && stat -f '%Sp' "$home" || echo '(missing)')"
    flags="$(is_admin "$u" && echo yes || echo no) $(has_password "$u" && echo yes || echo no)"
    # shellcheck disable=SC2086
    printf '  %-12s %-5s %-6s %-6s %-11s %s\n' "$u" "$uid" $flags "$perm" \
      "$(real_name "$u")"
  done

  log "Screen Sharing"
  if ss_enabled_in_launchd; then ok "launchd: enabled"; else warn "launchd: not enabled"; fi
  if port_listening 5900; then ok "listening on 5900 (reachable)"; else warn "not listening on 5900 (Screen Sharing is off)"; fi
  if vnc_legacy_on || [ -e "$VNC_PW_FILE" ]; then
    warn "\"VNC viewers may control screen with password\" is on - turn it off (add does this for you)"
  else
    ok "Shared VNC password: off"
  fi
  if pgrep -x ARDAgent >/dev/null 2>&1; then warn "ARDAgent is running (Remote Management on? It conflicts with Screen Sharing)"; fi

  log "Access allow lists"
  local g
  for g in "$SS_GROUP" "$SSH_GROUP"; do
    if group_exists "$g"; then
      printf '  %-32s only these users: %s\n' "$g" "$(group_members "$g")"
    elif group_exists "$g-disabled"; then
      printf '  %-32s %s\n' "$g" "disabled (= every user can connect!)"
    else
      printf '  %-32s %s\n' "$g" "missing (= every user can connect!)"
    fi
  done
  if port_listening 22; then ok "SSH (22) is listening"; else echo "  SSH (22) is not listening"; fi

  log "Current GUI sessions (each extra session uses a few GB of RAM)"
  local users
  users="$(gui_users | grep -v '^root$' | tr '\n' ' ' || true)"
  echo "  ${users:-(none)}"
  echo "  Memory: $(( $(sysctl -n hw.memsize) / 1073741824 )) GB; $(memory_pressure 2>/dev/null | awk -F': ' '/free percentage/ {print $2 " free"}')"
}

case "${1:-}" in
  add)    shift; cmd_add "$@" ;;
  remove) shift; cmd_remove "$@" ;;
  status) shift; cmd_status "$@" ;;
  -h|--help|help) usage 0 ;;
  *) usage ;;
esac
