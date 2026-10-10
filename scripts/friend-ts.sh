#!/usr/bin/env bash
# 用 Tailscale HTTP API v2 管理“分享给朋友”：朋友用他自己的 Tailscale 账号（节点分享，不拉进你的 tailnet），
# 再用 tailnet 策略（grants）限制他能访问本机的哪些端口。
#
#   friend-ts.sh invite [email]          给本机生成一个分享邀请链接（给了 email 就由 Tailscale 发邮件）
#   friend-ts.sh allow <email> [端口...]  允许这个朋友访问本机屏幕共享（tcp:5900 + udp:5900-5902）+ 额外端口
#   friend-ts.sh revoke <email>          删掉这个朋友的规则
#   friend-ts.sh cleanup                 删除离线的旧 chi-mini-* 节点
#   friend-ts.sh status                  设备、分享邀请、朋友相关规则
#
# `tailscale` CLI 改不了策略、也建不了分享，所以走 API：
#   令牌：管理后台 → Settings → Keys → Generate access token（https://login.tailscale.com/admin/settings/keys）
#         存到 ~/.config/chi/tailscale-api-key 并 chmod 600。令牌权限 = 你本人的权限，最长 90 天过期。
# API 文档：https://tailscale.com/api （OpenAPI：https://api.tailscale.com/api/v2?outputOpenapiSchema=true）
#
# 注意：策略用 JSON 形式读写，写回后后台策略里的 // 注释和排版会丢；每次写之前原 HuJSON 都备份在
#       ~/.config/chi/acl-backups/，想恢复就把备份内容贴回 Access Controls 页面。
set -euo pipefail
. "$(dirname "$0")/lib.sh"
ensure_brew_path

TOKEN_FILE="${CHI_TS_API_KEY_FILE:-$HOME/.config/chi/tailscale-api-key}"
API="${TS_API_BASE:-https://api.tailscale.com/api/v2}"
BACKUP_DIR="$HOME/.config/chi/acl-backups"
KEYS_PAGE="https://login.tailscale.com/admin/settings/keys"
# 屏幕共享：tcp:5900（VNC）+ udp:5900-5902（macOS「高性能」模式）。SSH(22) 故意不在默认里。
DEFAULT_PORTS="tcp:5900 udp:5900-5902"
# 收紧策略里给所有被分享用户（autogroup:shared）开放的端口，和 docs/onboarding.md 保持一致
SHARED_PORTS='["tcp:443","tcp:8008","tcp:8009","tcp:7890"]'

have jq   || die "需要 jq（brew install jq）"
have curl || die "需要 curl"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

usage() {
  cat <<EOF
用法: $(basename "$0") <命令>
  invite [email]          生成本机的分享邀请链接（单次有效，30 天内未接受自动失效）
  allow <email> [端口...]  允许该朋友访问本机：默认 tcp:5900 + udp:5900-5902（屏幕共享），可追加如 8010 / tcp:8003
  revoke <email>          删除该朋友的规则（不撤销分享本身）
  cleanup                 列出并删除离线的 chi-mini-* 旧节点（不含本机）
  status                  设备、本机的分享邀请、朋友相关规则

email 要写朋友接受邀请时用的 Tailscale 登录名（status 里 acceptedBy 那一列），不一定是你发邀请的邮箱。
EOF
}

# ---------- 令牌 / API ----------

load_token() {
  if [ ! -s "$TOKEN_FILE" ]; then
    die "没有 API 令牌：$TOKEN_FILE
    1) 打开 $KEYS_PAGE → Generate access token（建议 90 天）
    2) 复制令牌后：(umask 077 && mkdir -p ~/.config/chi && pbpaste > $TOKEN_FILE)
       （SSH 里没有剪贴板：(umask 077 && cat > $TOKEN_FILE)，粘贴，回车，Ctrl-D）"
  fi
  local mode
  mode="$(stat -f '%Lp' "$TOKEN_FILE" 2>/dev/null || stat -c '%a' "$TOKEN_FILE" 2>/dev/null || echo '?')"
  case "$mode" in
    600|400) ;;
    *) warn "$TOKEN_FILE 权限是 ${mode}，建议 chmod 600" ;;
  esac
  TOKEN="$(tr -d ' \r\n\t' <"$TOKEN_FILE")"
  case "$TOKEN" in
    tskey-api-*) ;;
    *) die "$TOKEN_FILE 里不像 API 访问令牌（应以 tskey-api- 开头；auth key / OAuth client secret 不行）" ;;
  esac
}

# api <METHOD> <path> [curl 参数...]
# 响应体写到 $TMP/body，响应头写到 $TMP/hdr，HTTP 状态码放在 ${HTTP}。非 2xx 时返回 1（调用方决定怎么处理）。
# 令牌经 stdin 以 curl 配置的形式传入，不出现在命令行（ps 看不到）里，也不打印。
HTTP=""
api() {
  local method="$1" path="$2"; shift 2
  : >"$TMP/body"; : >"$TMP/hdr"
  HTTP="$(printf 'header = "Authorization: Bearer %s"\n' "$TOKEN" |
    curl -sS -K - -X "$method" -D "$TMP/hdr" -o "$TMP/body" -w '%{http_code}' \
      --connect-timeout 10 --max-time 60 "$@" "$API$path")" || die "请求 $method $path 失败（网络？）"
  case "$HTTP" in 2??) return 0 ;; *) return 1 ;; esac
}

api_err() {
  local msg
  msg="$(jq -r '.message // empty' "$TMP/body" 2>/dev/null || true)"
  [ -n "$msg" ] || msg="$(head -c 400 "$TMP/body")"
  case "$HTTP" in
    401) printf 'HTTP 401：令牌无效或已过期 —— 去 %s 重新生成并覆盖 %s（%s）' "$KEYS_PAGE" "$TOKEN_FILE" "$msg" ;;
    403) printf 'HTTP 403：令牌所属用户没有权限（需要 Owner/Admin）（%s）' "$msg" ;;
    *)   printf 'HTTP %s：%s' "$HTTP" "$msg" ;;
  esac
}

api_ok() { api "$@" || die "$(api_err)"; }

header_val() { awk -v k="$1" 'tolower($0) ~ "^"tolower(k)":" {sub(/^[^:]*:[ \t]*/, ""); sub(/\r$/, ""); print}' "$TMP/hdr" | tail -n1; }

confirm() {
  local ans=""
  [ -t 0 ] || die "需要交互确认（stdin 不是终端），已放弃"
  printf '%s [y/N] ' "$1"
  read -r ans || true
  case "$ans" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

# ---------- 本机信息（来自本地 tailscaled，不需要令牌） ----------

SELF_ID=""; SELF_NAME=""; SELF_ADDRS="[]"; OWNER=""
load_self() {
  local st
  st="$(tailscale status --json 2>/dev/null)" || die "tailscale status 失败：tailscaled 在跑吗？（chi doctor）"
  SELF_ID="$(jq -r '.Self.ID // empty' <<<"$st")"
  SELF_NAME="$(jq -r '.Self.DNSName // "" | rtrimstr(".")' <<<"$st")"
  SELF_ADDRS="$(jq -c '.Self.TailscaleIPs // []' <<<"$st")"
  OWNER="$(jq -r '(.Self.UserID|tostring) as $u | .User[$u].LoginName // empty' <<<"$st")"
  [ -n "$SELF_ID" ] && [ "$SELF_ADDRS" != "[]" ] || die "拿不到本机节点 ID / IP（tailscale 还没登录？）"
}

# ---------- 策略处理（jq） ----------

# 公共 jq 定义：$e=朋友登录名，$a=本机地址数组（$ 是 jq 变量，不是 shell 变量）
# shellcheck disable=SC2016
JQ_DEFS='
  def has_el($x): any(.[]?; . == $x);
  def friend_rule($e; $a): (.src == [$e]) and ((.dst // []) | length > 0) and (((.dst // []) - $a) | length == 0);
  def acl_allow_all: (.action // "accept") == "accept"
      and (((.src // .users) // []) | has_el("*"))
      and (((.dst // .ports) // []) | has_el("*:*"));
  def grant_allow_all: ((.src // []) | has_el("*")) and ((.dst // []) | has_el("*"))
      and ((.ip // []) | has_el("*")) and (has("via") | not) and (has("srcPosture") | not);
  def has_allow_all: ([.acls[]? | select(acl_allow_all)] + [.grants[]? | select(grant_allow_all)]) | length > 0;
'

# 拉取当前策略：HuJSON 原文做备份，JSON 用来改；两次 ETag 必须一致（否则中途被人改了）
fetch_policy() {
  local etag_h etag_j ts
  api_ok GET "/tailnet/-/acl" -H "Accept: application/hujson"
  etag_h="$(header_val ETag)"
  mkdir -p "$BACKUP_DIR"; chmod 700 "$BACKUP_DIR"
  ts="$(date '+%Y%m%d-%H%M%S')"
  BACKUP="$BACKUP_DIR/policy-$ts.hujson"
  cp "$TMP/body" "$BACKUP"
  HAS_COMMENTS=0
  if grep -Eq '(^|[^:])//|/\*' "$BACKUP"; then HAS_COMMENTS=1; fi

  api_ok GET "/tailnet/-/acl" -H "Accept: application/json"
  etag_j="$(header_val ETag)"
  jq . "$TMP/body" >"$TMP/current.json" 2>/dev/null || die "策略 JSON 解析失败：$(head -c 200 "$TMP/body")"
  [ -n "$etag_j" ] || die "响应里没有 ETag，不敢无条件覆盖"
  if [ -n "$etag_h" ] && [ "$etag_h" != "$etag_j" ]; then
    die "两次读取之间策略被改过（ETag 不一致），重跑一次"
  fi
  ETAG="$etag_j"
  ok "已备份当前策略（HuJSON 原文）→ $BACKUP"
}

# 校验：POST /acl/validate（不改任何东西）。顺带塞一条测试：你本人必须仍能连本机 22 和 5900
validate_policy() {
  local ip4
  ip4="$(jq -r '[.[] | select(test("^[0-9.]+$"))][0] // .[0]' <<<"$SELF_ADDRS")"
  if [ -n "$OWNER" ]; then
    jq --arg o "$OWNER" --arg h "$ip4" \
      '.tests = ((.tests // []) + [{src: $o, accept: [($h + ":22"), ($h + ":5900")]}])' \
      "$TMP/new.json" >"$TMP/validate.json"
  else
    cp "$TMP/new.json" "$TMP/validate.json"
  fi
  api_ok POST "/tailnet/-/acl/validate" -H "Content-Type: application/json" --data-binary "@$TMP/validate.json"
  local msg
  msg="$(jq -r '.message // empty' "$TMP/body" 2>/dev/null || true)"
  if [ -n "$msg" ]; then
    jq . "$TMP/body" >&2 || cat "$TMP/body" >&2
    if jq -e '[.data[]?.errors[]?] | length > 0' "$TMP/body" >/dev/null 2>&1 || [ "$msg" != "warning(s) found" ]; then
      die "校验没通过：${msg}（什么都没改）"
    fi
    warn "校验有警告：$msg"
  else
    ok "校验通过（含测试：$OWNER 仍可访问 $ip4:22 和 :5900）"
  fi
}

# diff → 确认 → POST（带 If-Match）
write_policy() {
  if diff -q "$TMP/current.json" "$TMP/new.json" >/dev/null; then
    ok "策略没有变化，不用写"
    return 0
  fi
  validate_policy
  echo
  log "改动（JSON，- 旧 / + 新）："
  diff -u --label "当前策略" --label "新策略" "$TMP/current.json" "$TMP/new.json" || true
  echo
  if [ "$HAS_COMMENTS" = 1 ]; then
    warn "当前策略里有注释；API 以 JSON 写回后注释和排版会丢失（原文已备份：${BACKUP}）"
  fi
  confirm "写入 tailnet 策略？" || die "已取消，什么都没改"
  if ! api POST "/tailnet/-/acl" -H "Content-Type: application/json" -H "Accept: application/json" \
      -H "If-Match: $ETAG" --data-binary "@$TMP/new.json"; then
    [ "$HTTP" = 412 ] && die "策略在这期间被别人改过（If-Match 不匹配），重跑一次即可"
    die "写入失败：$(api_err)"
  fi
  ok "已写入。后台查看：https://login.tailscale.com/admin/acls/file"
}

normalize_ports() {
  # 输出 JSON 数组；5900 → tcp:5900，tcp:8000-8010 / udp:53 / * 原样
  local p out="" item
  for p in "$@"; do
    case "$p" in
      '*')                                   item='*' ;;
      tcp:*|udp:*|sctp:*)                    item="$p" ;;
      *[!0-9-]*|'')                          die "端口格式不对：${p}（例：5900、8000-8010、tcp:443、udp:53）" ;;
      *)                                     item="tcp:$p" ;;
    esac
    case "${item#*:}" in
      *[!0-9-]*) [ "$item" = '*' ] || die "端口格式不对：$p" ;;
    esac
    out="$out$item"$'\n'
  done
  printf '%s' "$out" | jq -R . | jq -cs 'unique'
}

check_email() {
  case "$1" in
    *@*) ;;
    *) die "要写朋友的 Tailscale 登录名（形如 friend@gmail.com 或 name@github）" ;;
  esac
  [ "$1" != "$OWNER" ] || die "$1 是你自己（owner），不需要朋友规则"
}

# ---------- 子命令 ----------

cmd_invite() {
  local email="${1:-}" body
  load_token; load_self
  body="$(jq -cn --arg e "$email" '[{multiUse: false, allowExitNode: false} + (if $e == "" then {} else {email: $e} end)]')"
  api_ok POST "/device/$SELF_ID/device-invites" -H "Content-Type: application/json" --data-binary "$body"
  local url
  url="$(jq -r '.[0].inviteUrl // empty' "$TMP/body")"
  [ -n "$url" ] || die "API 没返回 inviteUrl：$(head -c 300 "$TMP/body")"
  ok "已为 $SELF_NAME 生成单次邀请（id $(jq -r '.[0].id' "$TMP/body")，30 天内未接受自动失效）"
  [ -z "$email" ] || ok "Tailscale 已把邀请发到 ${email}（注意：朋友可以用任意账号接受，邀请不绑定这个邮箱）"
  printf '\n  %s\n\n' "$url"
  echo "朋友接受后跑：$(basename "$0") status   看他的登录名（acceptedBy），再：$(basename "$0") allow <登录名>"
}

cmd_allow() {
  [ "$#" -ge 1 ] || die "用法: $(basename "$0") allow <email> [端口...]"
  local email="$1"; shift
  load_token; load_self; check_email "$email"
  local ports
  # shellcheck disable=SC2086  # DEFAULT_PORTS 故意按空格拆开
  ports="$(normalize_ports $DEFAULT_PORTS "$@")"
  if jq -e 'any(.[]; . == "*" or . == "tcp:22")' <<<"$ports" >/dev/null; then
    warn "你给了 SSH(22) 或全部端口：朋友只该用屏幕共享，确定要开？（不想开就 Ctrl-C，或下面选 N）"
  fi
  fetch_policy

  # 先看朋友是否已接受分享（只提示，不阻止：也可以先写规则后接受）
  if api GET "/device/$SELF_ID/device-invites"; then
    if ! jq -e --arg e "$email" 'any(.[]?; .acceptedBy.loginName == $e)' "$TMP/body" >/dev/null; then
      warn "本机的已接受邀请里没有 $email —— 规则里的 email 必须是他接受邀请时的登录名（$(basename "$0") status 可查）"
    fi
  fi

  local tighten=0
  if jq -e "$JQ_DEFS has_allow_all" "$TMP/current.json" >/dev/null; then
    warn "当前策略里有 allow-all 规则（src \"*\" → 全部端口）：被分享的用户（autogroup:shared）已经能访问本机所有端口，"
    warn "单加一条朋友规则起不到限制作用。建议收紧为：你的成员设备全权限 + autogroup:shared 只开 $(jq -r 'join(" ")' <<<"$SHARED_PORTS") + 这个朋友额外的端口。"
    if confirm "用收紧后的策略替换 allow-all 规则？"; then
      tighten=1
    else
      warn "不收紧：照样加朋友规则，但在 allow-all 存在时它不起限制作用"
    fi
  fi

  local tagged="false"
  if [ "$tighten" = 1 ] && api GET "/tailnet/-/devices"; then
    tagged="$(jq '[.devices[]? | select((.tags // []) | length > 0)] | length > 0' "$TMP/body")"
  fi

  jq --arg e "$email" --argjson a "$SELF_ADDRS" --argjson p "$ports" \
     --argjson tighten "$tighten" --argjson shared "$SHARED_PORTS" --argjson tagged "$tagged" "$JQ_DEFS"'
    (if $tighten == 1 then
       .acls = [.acls[]? | select(acl_allow_all | not)]
       | .grants = [.grants[]? | select(grant_allow_all | not)]
       | (if (.acls | length) == 0 then del(.acls) else . end)
       | .grants = [
           {src: ["autogroup:member"], dst: ["*"], ip: ["*"]}
         ] + (if $tagged then [{src: ["autogroup:tagged"], dst: ["*"], ip: ["*"]}] else [] end)
           + (if any(.grants[]; .src == ["autogroup:shared"]) then [] else [{src: ["autogroup:shared"], dst: ["*"], ip: $shared}] end)
           + .grants
     else . end)
    # 已有这个朋友的规则就原地替换（diff 干净），多余的重复删掉；没有就追加到末尾
    | {src: [$e], dst: $a, ip: $p} as $new
    | (.grants // []) as $g
    | if any($g[]; friend_rule($e; $a)) then
        .grants = (reduce $g[] as $r ({out: [], done: false};
          if ($r | friend_rule($e; $a)) then
            (if .done then . else .out += [$new] | .done = true end)
          else .out += [$r] end) | .out)
      else .grants = $g + [$new] end
  ' "$TMP/current.json" >"$TMP/new.json"

  log "朋友 $email → ${SELF_NAME}（$(jq -r 'join(", ")' <<<"$SELF_ADDRS")）：$(jq -r 'join(" ")' <<<"$ports")"
  write_policy
  echo "朋友在他的 Mac 上：访达 → 前往 → 连接服务器 → vnc://${SELF_NAME}，用他自己的 macOS 账号登录（账号见 scripts/friend-mac.sh）。"
}

cmd_revoke() {
  [ "$#" -eq 1 ] || die "用法: $(basename "$0") revoke <email>"
  local email="$1"
  load_token; load_self
  fetch_policy
  local n
  n="$(jq --arg e "$email" --argjson a "$SELF_ADDRS" "$JQ_DEFS"'[.grants[]? | select(friend_rule($e; $a))] | length' "$TMP/current.json")"
  if [ "$n" = 0 ]; then
    warn "策略里没有 $email → 本机 的朋友规则"
  fi
  jq --arg e "$email" --argjson a "$SELF_ADDRS" "$JQ_DEFS"'
    if has("grants") then .grants = [.grants[] | select(friend_rule($e; $a) | not)] else . end
  ' "$TMP/current.json" >"$TMP/new.json"
  if jq -e --arg e "$email" '[.. | strings | select(. == $e)] | length > 0' "$TMP/new.json" >/dev/null; then
    warn "$email 在策略的其他地方还出现过（groups/acls/ssh 等），这里没动，自己去后台看"
  fi
  write_policy
  echo "注意：这只删了他的额外端口；他仍是被分享用户（autogroup:shared 的端口照样能用）。"
  echo "要彻底断开：https://login.tailscale.com/admin/machines → ${SELF_NAME%%.*} → Share… → Revoke。"
}

cmd_cleanup() {
  load_token; load_self
  local base="${SELF_NAME%%.*}"
  base="${base%-[0-9]*}"
  api_ok GET "/tailnet/-/devices"
  jq -r --arg self "$SELF_ID" --arg base "$base" '
    .devices[]
    | select(.nodeId != $self and (.isExternal | not) and (.connectedToControl != true))
    | select(((.name // "") | split(".")[0]) as $n | $n == $base or ($n | test("^" + $base + "-[0-9]+$")))
    | [.nodeId, (.name // .hostname), (.os // "?"), (.lastSeen // "从未在线")] | @tsv
  ' "$TMP/body" >"$TMP/stale.tsv"
  if [ ! -s "$TMP/stale.tsv" ]; then
    ok "没有离线的 $base / $base-* 旧节点"
    return 0
  fi
  log "这些节点离线且不是本机（${SELF_ID}）："
  awk -F'\t' '{printf "  %-22s %-40s %-8s 最后在线 %s\n", $1, $2, $3, $4}' "$TMP/stale.tsv"
  confirm "全部删除？（删除后那台机器要重新登录才能回来）" || die "已取消"
  local id name _os _seen
  while IFS="$(printf '\t')" read -r id name _os _seen; do
    if api DELETE "/device/$id"; then ok "已删除 $name"; else warn "删除 $name 失败：$(api_err)"; fi
  done <"$TMP/stale.tsv"
  if [ "${SELF_NAME%%.*}" != "$base" ]; then
    echo "本机现在叫 ${SELF_NAME%%.*}：旧节点删掉后可在后台改回 ${base}（Machines → … → Edit machine name），改名后 TS_FQDN 和 chi serve 也要跟着改。"
  fi
}

cmd_status() {
  load_token; load_self
  log "设备（本机 = ${SELF_NAME}，${SELF_ID}）"
  api_ok GET "/tailnet/-/devices"
  jq -r '.devices | sort_by(.name)[]
    | [ (if .connectedToControl then "在线" else "离线" end),
        (.name // .hostname), (.addresses[0] // "-"), (.os // "?"), (.user // "-"),
        (if .isExternal then "分享进来" else "" end), (.lastSeen // "") ] | @tsv' "$TMP/body" |
    awk -F'\t' '{printf "  %-4s %-40s %-16s %-8s %-28s %s %s\n", $1, $2, $3, $4, $5, $6, $7}'

  echo
  log "本机的分享邀请"
  if api GET "/device/$SELF_ID/device-invites"; then
    if [ "$(jq 'length' "$TMP/body")" = 0 ]; then
      echo "  （没有）"
    else
      jq -r '.[] | [ .id, (.created // "" | .[0:10]),
          (if .accepted then "已接受 by " + (.acceptedBy.loginName // "?") else "未接受" end),
          (.email // "-"), (if .accepted then "" else (.inviteUrl // "") end) ] | @tsv' "$TMP/body" |
        awk -F'\t' '{printf "  %-10s %s  %-40s 邮件:%-24s %s\n", $1, $2, $3, $4, $5}'
    fi
  else
    warn "读不到邀请：$(api_err)"
  fi

  echo
  log "策略里和朋友有关的规则"
  api_ok GET "/tailnet/-/acl" -H "Accept: application/json"
  cp "$TMP/body" "$TMP/current.json"
  if jq -e "$JQ_DEFS has_allow_all" "$TMP/current.json" >/dev/null; then
    warn "有 allow-all 规则：被分享的用户能访问本机全部端口（跑 allow 时会提议收紧）"
  fi
  jq -r --argjson a "$SELF_ADDRS" "$JQ_DEFS"'
    [.grants[]? | select(((.src // []) | has_el("autogroup:shared"))
                         or ((.dst // []) | length > 0 and ((. - $a) | length == 0)))]
    | if length == 0 then "  （没有）" else .[] | "  " + (.src | join(",")) + "  →  " + (.dst | join(",")) + "  :  " + ((.ip // ["*"]) | join(" ")) end
  ' "$TMP/current.json"
}

cmd="${1:-help}"
[ "$#" -gt 0 ] && shift
case "$cmd" in
  invite)  cmd_invite "$@" ;;
  allow)   cmd_allow "$@" ;;
  revoke)  cmd_revoke "$@" ;;
  cleanup) cmd_cleanup "$@" ;;
  status)  cmd_status "$@" ;;
  help|-h|--help) usage ;;
  *) usage; exit 1 ;;
esac
