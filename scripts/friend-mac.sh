#!/usr/bin/env bash
# 让朋友用他自己的 macOS 账号，通过「屏幕共享」远程用这台 Mac（和你同时用，互不干扰）。
#
# 用法（用你自己的管理员账号跑，不要加 sudo，脚本里需要时会自己要 sudo 密码）：
#   scripts/friend-mac.sh add <用户名> [全名] [--ssh]   建账号/补密码、收紧权限、加进屏幕共享白名单
#   scripts/friend-mac.sh status                        查看现状（不需要 root）
#   scripts/friend-mac.sh remove <用户名> [--delete]    移出白名单；--delete 连账号带家目录一起删
#
# 背景（细节见 docs/onboarding.md）：
# - 屏幕共享的「仅这些用户」= 本地组 com.apple.access_screensharing（SACL）；
#   远程登录（SSH）的「仅这些用户」= com.apple.access_ssh，由 sshd 的 PAM 模块 pam_sacl 检查。
#   系统设置里选「所有用户」时，系统会把组改名成 xxx-disabled 让它失效；本脚本按同样的约定处理。
# - macOS 12.1 起 Apple 明确不允许用 kickstart 打开屏幕共享。这里用 launchctl enable + bootstrap，
#   属于非官方做法，失败时会打印系统设置的点击路径。
# - 「VNC 用户可以使用密码控制屏幕」（VNCLegacyConnectionsEnabled）必须关：那是一个所有人共用的
#   弱密码，绕开账号体系，也不能“以自己身份登录”。
set -euo pipefail
. "$(dirname "$0")/lib.sh"
require_macos

SS_GROUP=com.apple.access_screensharing
SSH_GROUP=com.apple.access_ssh
SS_PLIST=/System/Library/LaunchDaemons/com.apple.screensharing.plist
RM_PREFS=/Library/Preferences/com.apple.RemoteManagement
VNC_PW_FILE=/Library/Preferences/com.apple.VNCSettings.txt
# 机器的 Tailscale 域名从 .env 读（chi init 填的 TS_FQDN）；仓库是公开的，不要把真实 tailnet 名写死在这里
if [ -f "$CHI_ROOT/.env" ]; then load_env; fi
HOST_FQDN="${TS_FQDN:-<你的机器>.<tailnet>.ts.net}"
OWNER="$(id -un)"

usage() {
  sed -n '4,7p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-1}"
}

# ---------- 小工具（都不需要 root） ----------
user_exists()  { dscl . -read "/Users/$1" UniqueID >/dev/null 2>&1; }
group_exists() { dscl . -read "/Groups/$1" PrimaryGroupID >/dev/null 2>&1; }
is_member()    { dseditgroup -o checkmember -m "$1" "$2" >/dev/null 2>&1; }
is_admin()     { is_member "$1" admin; }
# 用 sysadminctl -addUser 不带 -password 建的账号没有 AuthenticationAuthority，登录不了
has_password() { dscl . -read "/Users/$1" AuthenticationAuthority >/dev/null 2>&1; }
user_home()    { dscl . -read "/Users/$1" NFSHomeDirectory 2>/dev/null | awk '{print $2}'; }
# 单个词的值和 key 在同一行，带空格的值会换到下一行，两种都处理
real_name()    { dscl . -read "/Users/$1" RealName 2>/dev/null | sed -e '1s/^RealName:[[:space:]]*//' -e 's/^[[:space:]]*//' | tr -d '\n'; }
user_uid()     { dscl . -read "/Users/$1" UniqueID 2>/dev/null | awk '{print $2}'; }
port_listening() { netstat -an -p tcp 2>/dev/null | grep -Eq "[.:]$1 .*LISTEN"; }
vnc_legacy_on() { [ "$(defaults read "$RM_PREFS" VNCLegacyConnectionsEnabled 2>/dev/null || echo 0)" = "1" ]; }
ss_enabled_in_launchd() { launchctl print-disabled system 2>/dev/null | grep -q '"com.apple.screensharing" => enabled'; }
ss_loaded() { launchctl print system/com.apple.screensharing >/dev/null 2>&1; }
# 有图形会话（含屏幕共享开出来的后台会话）的用户
gui_users() { ps -axo user=,comm= 2>/dev/null | awk '$2 ~ /loginwindow$/ {print $1}' | sort -u; }

valid_username() {
  case "$1" in
    ''|*[!a-z0-9_.-]*|[!a-z_]*) return 1 ;;
  esac
  [ "${#1}" -le 31 ]
}

# 组成员：直接成员 + 嵌套组（转成组名）
group_members() {
  local g="$1" members nested guid name
  members="$(dscl . -read "/Groups/$g" GroupMembership 2>/dev/null | sed 's/^GroupMembership://' | xargs || true)"
  nested=""
  for guid in $(dscl . -read "/Groups/$g" NestedGroups 2>/dev/null | sed 's/^NestedGroups://'); do
    name="$(dscl . -search /Groups GeneratedUID "$guid" 2>/dev/null | awk 'NR==1{print $1}')"
    nested="$nested ${name:-$guid}(组)"
  done
  printf '%s%s\n' "${members:-（无直接成员）}" "$nested"
}

# 确保 SACL 组处于“生效”状态：已存在就不动；有 xxx-disabled 就改回原名（保留里面的 admin 嵌套组，
# 和在系统设置里点「仅这些用户」效果一样）；都没有就新建。然后总是把管理员本人加进去，防止把自己锁在外面。
ensure_sacl_group() {
  local g="$1" desc="$2"
  if group_exists "$g"; then
    :
  elif group_exists "$g-disabled"; then
    log "启用 ${g}（把 $g-disabled 改回原名，等于系统设置里选「仅这些用户」）"
    sudo dscl . -change "/Groups/$g-disabled" RecordName "$g-disabled" "$g"
  else
    log "创建 $g"
    sudo dseditgroup -o create -r "$desc" -q "$g"
  fi
  if ! is_member "$OWNER" "$g"; then
    sudo dseditgroup -o edit -a "$OWNER" -t user "$g"
  fi
}

group_add() {
  local u="$1" g="$2"
  if is_member "$u" "$g"; then
    ok "$u 已在 $g"
  else
    sudo dseditgroup -o edit -a "$u" -t user "$g"
    ok "$u → $g"
  fi
}

group_del() {
  local u="$1" g="$2"
  group_exists "$g" || return 0
  # checkmember 会把嵌套组也算进去，所以只看直接成员
  if dscl . -read "/Groups/$g" GroupMembership 2>/dev/null | tr ' ' '\n' | grep -qx "$u"; then
    sudo dseditgroup -o edit -d "$u" -t user "$g"
    ok "$u 已移出 $g"
  fi
}

print_click_path() {
  cat <<EOF
  请手动打开：系统设置 → 通用 → 共享 → 「屏幕共享」开关打开 → 点旁边的 (i)：
    · 「VNC 用户可以使用密码控制屏幕」  关
    · 「允许访问」选「仅这些用户」，列表里有你自己（或“管理员”）和朋友
  （开屏幕共享前要先关「远程管理」，两者互斥。）
EOF
}

ensure_screen_sharing_on() {
  if port_listening 5900; then
    ok "屏幕共享已开（5900 在监听）"
    return 0
  fi
  if pgrep -x ARDAgent >/dev/null 2>&1; then
    warn "「远程管理」(ARD) 好像开着，它和屏幕共享互斥，请先在 系统设置 → 通用 → 共享 里关掉"
  fi
  log "尝试用 launchctl 打开屏幕共享（非官方做法，Apple 文档只说 12.1 起 kickstart 不行了）"
  sudo launchctl enable system/com.apple.screensharing || true
  ss_loaded || sudo launchctl bootstrap system "$SS_PLIST" 2>/dev/null || true
  local i=0
  while [ $i -lt 5 ] && ! port_listening 5900; do
    sleep 1; i=$((i + 1))
  done
  if port_listening 5900; then
    ok "屏幕共享已开（5900 在监听）。建议还是去系统设置里看一眼开关状态是否一致"
  else
    warn "命令行没能打开屏幕共享"
    print_click_path
  fi
}

ensure_vnc_password_off() {
  if vnc_legacy_on || sudo test -f "$VNC_PW_FILE"; then
    log "关闭「VNC 用户可以使用密码控制屏幕」"
    sudo defaults write "$RM_PREFS" VNCLegacyConnectionsEnabled -bool false
    sudo rm -f "$VNC_PW_FILE"
    ok "VNC 共享密码已关闭并删除"
  else
    ok "VNC 共享密码未开启"
  fi
}

# ---------- add ----------
cmd_add() {
  local user="" full="" want_ssh=0 arg
  for arg in "$@"; do
    case "$arg" in
      --ssh) want_ssh=1 ;;
      -h|--help) usage 0 ;;
      -*) die "不认识的参数：$arg" ;;
      *) if [ -z "$user" ]; then user="$arg"; elif [ -z "$full" ]; then full="$arg"; else die "参数太多：$arg"; fi ;;
    esac
  done
  [ -n "$user" ] || usage
  valid_username "$user" || die "用户名只能用小写字母/数字/_.-，且以字母或 _ 开头：$user"
  [ "$user" != "$OWNER" ] && [ "$user" != root ] || die "不能对 $user 自己做这个"
  [ "$(id -u)" -ne 0 ] || die "不要用 sudo 跑这个脚本，用你自己的管理员账号直接跑（需要时会问 sudo 密码）"
  is_admin "$OWNER" || die "$OWNER 不是管理员，没法做这些设置"

  log "给 $user 配置屏幕共享（会要你的 sudo 密码）"
  sudo -v

  # 1) 账号 + 密码
  if ! user_exists "$user"; then
    log "创建标准用户 ${user}（下面会提示输入他的登录密码）"
    sudo sysadminctl -addUser "$user" -fullName "${full:-$user}" -password -
    user_exists "$user" || die "创建 $user 失败"
    ok "已创建 $user"
  else
    ok "$user 已存在（UID $(user_uid "$user")）"
    if [ -n "$full" ]; then
      sudo dscl . -create "/Users/$user" RealName "$full"   # -create 会覆盖原值
    fi
  fi
  is_admin "$user" && die "$user 是管理员。朋友账号必须是标准用户：系统设置 → 用户与群组 里取消「允许此用户管理这台电脑」后重跑"

  if has_password "$user"; then
    ok "$user 已有登录密码（要改就跑：sudo sysadminctl -resetPasswordFor $user -newPassword -）"
  else
    log "$user 还没有密码，现在设置（会提示输入新密码）"
    # sysadminctl 失败时退出码经常还是 0，所以以 AuthenticationAuthority 是否出现为准
    sudo sysadminctl -resetPasswordFor "$user" -newPassword - || true
    if ! has_password "$user"; then
      warn "sysadminctl 没设成功，改用 dscl 再试一次"
      sudo dscl . -passwd "/Users/$user"
    fi
    has_password "$user" || die "$user 的密码还是没设上，请到 系统设置 → 用户与群组 里给他设密码"
    ok "$user 的密码已设置"
  fi

  # 2) 家目录只给本人（macOS 默认是 750，同组 staff 的人都能列目录）
  local home u
  for u in "$OWNER" "$user"; do
    home="$(user_home "$u")"
    if [ -n "$home" ] && [ -d "$home" ]; then
      if [ "$(stat -f '%Lp' "$home")" != "700" ]; then
        sudo chmod 700 "$home"
        ok "$home → 700"
      else
        ok "$home 已是 700"
      fi
    else
      warn "$u 的家目录 ${home:-?} 还不存在（首次登录才会建），登录过一次后再跑一遍本命令"
    fi
  done

  # 3) 屏幕共享白名单
  ensure_sacl_group "$SS_GROUP" "Screensharing Service ACL"
  group_add "$user" "$SS_GROUP"

  # 4) SSH 白名单：默认只给管理员，朋友要 --ssh 才加
  ensure_sacl_group "$SSH_GROUP" "SSH Service ACL"
  if [ "$want_ssh" = 1 ]; then
    group_add "$user" "$SSH_GROUP"
  else
    group_del "$user" "$SSH_GROUP"
    ok "SSH 只允许 $SSH_GROUP 里的人（管理员 + ${OWNER}），$user 不能 SSH（要的话加 --ssh 重跑）"
  fi

  # 5) VNC 共享密码关掉，屏幕共享打开
  ensure_vnc_password_off
  ensure_screen_sharing_on

  echo
  ok "完成。让朋友这样连（他那边要先连上 Tailscale）："
  cat <<EOF
  Mac 上：打开「屏幕共享」App（或 Finder → 前往 → 连接服务器）→ vnc://$HOST_FQDN
         → 用户名 $user + 他的密码 → 提示有人在用时选「以自己身份登录」
  首次登录后他自己：设置 Apple 账户可以，但「查找」里的「查找我的 Mac」不要开（会给这台机器上激活锁）
EOF
  warn "建议到 系统设置 → 通用 → 共享 → 屏幕共享 (i) 里核对一遍：VNC 密码关、仅这些用户"
}

# ---------- remove ----------
cmd_remove() {
  local user="" del=0 arg
  for arg in "$@"; do
    case "$arg" in
      --delete) del=1 ;;
      -h|--help) usage 0 ;;
      -*) die "不认识的参数：$arg" ;;
      *) [ -z "$user" ] || die "参数太多：$arg"; user="$arg" ;;
    esac
  done
  [ -n "$user" ] || usage
  [ "$user" != "$OWNER" ] && [ "$user" != root ] || die "不能对 $user 自己做这个"
  [ "$(id -u)" -ne 0 ] || die "不要用 sudo 跑这个脚本"
  user_exists "$user" || die "没有用户 $user"
  is_admin "$user" && die "$user 是管理员，这个脚本不处理管理员账号"

  sudo -v
  group_del "$user" "$SS_GROUP"
  group_del "$user" "$SSH_GROUP"

  if gui_users | grep -qx "$user"; then
    warn "$user 现在还有登录着的会话。移出白名单不会踢掉已连接的人，要立刻踢掉："
    echo "  sudo launchctl bootout gui/$(user_uid "$user")"
  fi

  if [ "$del" = 1 ]; then
    local ans=""
    printf '要删除账号 %s 和他的家目录 %s（不可恢复）。输入用户名确认：' "$user" "$(user_home "$user")"
    read -r ans
    [ "$ans" = "$user" ] || die "没确认，取消"
    sudo sysadminctl -deleteUser "$user"
    if user_exists "$user"; then
      die "删除失败（他还登录着的话先踢掉会话再试）"
    fi
    ok "已删除账号 $user"
  else
    ok "$user 已不能再用屏幕共享 / SSH 登录（账号还在，加 --delete 才删）"
  fi
}

# ---------- status ----------
cmd_status() {
  local u uid home perm flags
  log "本机用户（UID ≥ 500）"
  printf '  %-12s %-5s %-6s %-6s %-11s %s\n' 用户 UID 管理员 有密码 家目录权限 全名
  dscl . -list /Users UniqueID | awk '$2 >= 500 {print $1, $2}' | while read -r u uid; do
    home="$(user_home "$u")"
    perm="$( [ -d "$home" ] && stat -f '%Sp' "$home" || echo '(不存在)')"
    flags="$(is_admin "$u" && echo 是 || echo 否) $(has_password "$u" && echo 是 || echo 否)"
    # shellcheck disable=SC2086
    printf '  %-12s %-5s %-6s %-6s %-11s %s\n' "$u" "$uid" $flags "$perm" \
      "$(real_name "$u")"
  done

  log "屏幕共享"
  if ss_enabled_in_launchd; then ok "launchd：已启用"; else warn "launchd：未启用"; fi
  if port_listening 5900; then ok "5900 在监听（能连）"; else warn "5900 没在监听（屏幕共享没开）"; fi
  if vnc_legacy_on || [ -e "$VNC_PW_FILE" ]; then
    warn "「VNC 用户可以使用密码控制屏幕」开着 → 应该关掉（跑 add 会自动关）"
  else
    ok "VNC 共享密码：关"
  fi
  if pgrep -x ARDAgent >/dev/null 2>&1; then warn "ARDAgent 在运行（远程管理开着？它和屏幕共享互斥）"; fi

  log "访问白名单"
  local g
  for g in "$SS_GROUP" "$SSH_GROUP"; do
    if group_exists "$g"; then
      printf '  %-32s 仅这些用户：%s\n' "$g" "$(group_members "$g")"
    elif group_exists "$g-disabled"; then
      printf '  %-32s %s\n' "$g" "未生效（=所有用户都能连！）"
    else
      printf '  %-32s %s\n' "$g" "不存在（=所有用户都能连！）"
    fi
  done
  if port_listening 22; then ok "SSH（22）在监听"; else echo "  SSH（22）没在监听"; fi

  log "当前图形会话（每多一个会话就多占几 GB 内存）"
  local users
  users="$(gui_users | grep -v '^root$' | tr '\n' ' ' || true)"
  echo "  ${users:-（无）}"
  echo "  内存：$(( $(sysctl -n hw.memsize) / 1073741824 )) GB；$(memory_pressure 2>/dev/null | awk -F': ' '/free percentage/ {print "空闲 " $2}')"
}

case "${1:-}" in
  add)    shift; cmd_add "$@" ;;
  remove) shift; cmd_remove "$@" ;;
  status) shift; cmd_status "$@" ;;
  -h|--help|help) usage 0 ;;
  *) usage ;;
esac
