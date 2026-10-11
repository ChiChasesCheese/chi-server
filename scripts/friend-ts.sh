#!/usr/bin/env bash
# Manage "share with a friend" through the Tailscale HTTP API v2: the friend keeps their own Tailscale account
# (node sharing - they are not added to your tailnet), and tailnet policy grants limit which ports on this machine they can reach.
#
#   friend-ts.sh invite [email]           create a share invite link for this machine (with an email, Tailscale sends it)
#   friend-ts.sh allow <email> [port...]  let this friend reach Screen Sharing here (tcp:5900 + udp:5900-5902) + extra ports
#   friend-ts.sh revoke <email>           delete this friend's rule
#   friend-ts.sh cleanup                  delete stale offline chi-mini-* nodes
#   friend-ts.sh status                   devices, share invites, friend-related rules
#
# The `tailscale` CLI can't edit policy or create shares, so we use the API:
#   Token: admin console -> Settings -> Keys -> Generate access token (https://login.tailscale.com/admin/settings/keys)
#          Save it to ~/.config/chi/tailscale-api-key and chmod 600. The token has your own permissions and expires in 90 days at most.
# API docs: https://tailscale.com/api (OpenAPI: https://api.tailscale.com/api/v2?outputOpenapiSchema=true)
#
# Note: policy is read and written as JSON, so // comments and formatting in the admin console are lost on write. Before each
#       write the original HuJSON is backed up to ~/.config/chi/acl-backups/; to restore, paste a backup into the Access Controls page.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
ensure_brew_path

TOKEN_FILE="${CHI_TS_API_KEY_FILE:-$HOME/.config/chi/tailscale-api-key}"
API="${TS_API_BASE:-https://api.tailscale.com/api/v2}"
BACKUP_DIR="$HOME/.config/chi/acl-backups"
KEYS_PAGE="https://login.tailscale.com/admin/settings/keys"
# Screen Sharing: tcp:5900 (VNC) + udp:5900-5902 (macOS High Performance mode). SSH (22) is left out on purpose.
DEFAULT_PORTS="tcp:5900 udp:5900-5902"
# Ports opened to all share recipients (autogroup:shared) in the tightened policy; keep in sync with docs/guest-access.md
SHARED_PORTS='["tcp:443","tcp:8008","tcp:8009","tcp:7890"]'

have jq   || die "Needs jq (brew install jq)"
have curl || die "Needs curl"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

usage() {
  cat <<EOF
Usage: $(basename "$0") <command>
  invite [email]          create a share invite link for this machine (single use, expires if not accepted in 30 days)
  allow <email> [port...] let this friend reach this machine: tcp:5900 + udp:5900-5902 (Screen Sharing) by default, plus e.g. 8010 / tcp:8003
  revoke <email>          delete this friend's rule (does not revoke the share itself)
  cleanup                 list and delete stale offline chi-mini-* nodes (never this machine)
  status                  devices, this machine's share invites, friend-related rules

<email> is the Tailscale login the friend used to accept the invite (the acceptedBy column in status), not necessarily the address you invited.
EOF
}

# ---------- Token / API ----------

load_token() {
  if [ ! -s "$TOKEN_FILE" ]; then
    die "No API token: $TOKEN_FILE
    1) Open $KEYS_PAGE -> Generate access token (90 days recommended)
    2) Copy the token, then: (umask 077 && mkdir -p ~/.config/chi && pbpaste > $TOKEN_FILE)
       (over SSH there is no clipboard: (umask 077 && cat > $TOKEN_FILE), paste, Enter, Ctrl-D)"
  fi
  local mode
  mode="$(stat -f '%Lp' "$TOKEN_FILE" 2>/dev/null || stat -c '%a' "$TOKEN_FILE" 2>/dev/null || echo '?')"
  case "$mode" in
    600|400) ;;
    *) warn "$TOKEN_FILE has mode ${mode}; chmod 600 recommended" ;;
  esac
  TOKEN="$(tr -d ' \r\n\t' <"$TOKEN_FILE")"
  case "$TOKEN" in
    tskey-api-*) ;;
    *) die "$TOKEN_FILE does not look like an API access token (should start with tskey-api-; auth keys and OAuth client secrets won't work)" ;;
  esac
}

# api <METHOD> <path> [curl args...]
# Body goes to $TMP/body, headers to $TMP/hdr, the HTTP status to ${HTTP}. Returns 1 on non-2xx (the caller decides what to do).
# The token is passed on stdin as curl config, so it never appears on the command line (invisible to ps) and is never printed.
HTTP=""
api() {
  local method="$1" path="$2"; shift 2
  : >"$TMP/body"; : >"$TMP/hdr"
  HTTP="$(printf 'header = "Authorization: Bearer %s"\n' "$TOKEN" |
    curl -sS -K - -X "$method" -D "$TMP/hdr" -o "$TMP/body" -w '%{http_code}' \
      --connect-timeout 10 --max-time 60 "$@" "$API$path")" || die "Request $method $path failed (network?)"
  case "$HTTP" in 2??) return 0 ;; *) return 1 ;; esac
}

api_err() {
  local msg
  msg="$(jq -r '.message // empty' "$TMP/body" 2>/dev/null || true)"
  [ -n "$msg" ] || msg="$(head -c 400 "$TMP/body")"
  case "$HTTP" in
    401) printf 'HTTP 401: token invalid or expired - generate a new one at %s and overwrite %s (%s)' "$KEYS_PAGE" "$TOKEN_FILE" "$msg" ;;
    403) printf 'HTTP 403: the token owner lacks permission (needs Owner/Admin) (%s)' "$msg" ;;
    *)   printf 'HTTP %s: %s' "$HTTP" "$msg" ;;
  esac
}

api_ok() { api "$@" || die "$(api_err)"; }

header_val() { awk -v k="$1" 'tolower($0) ~ "^"tolower(k)":" {sub(/^[^:]*:[ \t]*/, ""); sub(/\r$/, ""); print}' "$TMP/hdr" | tail -n1; }

confirm() {
  local ans=""
  [ -t 0 ] || die "Needs interactive confirmation (stdin is not a terminal); giving up"
  printf '%s [y/N] ' "$1"
  read -r ans || true
  case "$ans" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

# ---------- This machine (from the local tailscaled, no token needed) ----------

SELF_ID=""; SELF_NAME=""; SELF_ADDRS="[]"; OWNER=""
load_self() {
  local st
  st="$(tailscale status --json 2>/dev/null)" || die "tailscale status failed: is tailscaled running? (chi doctor)"
  SELF_ID="$(jq -r '.Self.ID // empty' <<<"$st")"
  SELF_NAME="$(jq -r '.Self.DNSName // "" | rtrimstr(".")' <<<"$st")"
  SELF_ADDRS="$(jq -c '.Self.TailscaleIPs // []' <<<"$st")"
  OWNER="$(jq -r '(.Self.UserID|tostring) as $u | .User[$u].LoginName // empty' <<<"$st")"
  [ -n "$SELF_ID" ] && [ "$SELF_ADDRS" != "[]" ] || die "Could not get this node's ID / IP (is tailscale logged in?)"
}

# ---------- Policy handling (jq) ----------

# Shared jq definitions: $e = friend's login, $a = array of this machine's addresses ($ are jq variables, not shell ones)
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

# Fetch the current policy: raw HuJSON for the backup, JSON for editing. Both ETags must match (else it changed in between)
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
  jq . "$TMP/body" >"$TMP/current.json" 2>/dev/null || die "Could not parse policy JSON: $(head -c 200 "$TMP/body")"
  [ -n "$etag_j" ] || die "No ETag in the response; refusing to overwrite blindly"
  if [ -n "$etag_h" ] && [ "$etag_h" != "$etag_j" ]; then
    die "Policy changed between reads (ETag mismatch); run again"
  fi
  ETAG="$etag_j"
  ok "Backed up current policy (raw HuJSON) -> $BACKUP"
}

# Validate via POST /acl/validate (changes nothing). Also adds a test: you must still reach this machine on 22 and 5900
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
      die "Validation failed: ${msg} (nothing changed)"
    fi
    warn "Validation warnings: $msg"
  else
    ok "Validation passed (incl. test: $OWNER can still reach $ip4:22 and :5900)"
  fi
}

# diff -> confirm -> POST (with If-Match)
write_policy() {
  if diff -q "$TMP/current.json" "$TMP/new.json" >/dev/null; then
    ok "Policy unchanged, nothing to write"
    return 0
  fi
  validate_policy
  echo
  log "Changes (JSON, - old / + new):"
  diff -u --label "current policy" --label "new policy" "$TMP/current.json" "$TMP/new.json" || true
  echo
  if [ "$HAS_COMMENTS" = 1 ]; then
    warn "The current policy has comments; writing JSON through the API drops comments and formatting (original backed up: ${BACKUP})"
  fi
  confirm "Write tailnet policy?" || die "Cancelled, nothing changed"
  if ! api POST "/tailnet/-/acl" -H "Content-Type: application/json" -H "Accept: application/json" \
      -H "If-Match: $ETAG" --data-binary "@$TMP/new.json"; then
    [ "$HTTP" = 412 ] && die "Policy was changed by someone else meanwhile (If-Match failed); just run again"
    die "Write failed: $(api_err)"
  fi
  ok "Written. View it at https://login.tailscale.com/admin/acls/file"
}

normalize_ports() {
  # Prints a JSON array; 5900 -> tcp:5900, while tcp:8000-8010 / udp:53 / * pass through as-is
  local p out="" item
  for p in "$@"; do
    case "$p" in
      '*')                                   item='*' ;;
      tcp:*|udp:*|sctp:*)                    item="$p" ;;
      *[!0-9-]*|'')                          die "Bad port format: ${p} (e.g. 5900, 8000-8010, tcp:443, udp:53)" ;;
      *)                                     item="tcp:$p" ;;
    esac
    case "${item#*:}" in
      *[!0-9-]*) [ "$item" = '*' ] || die "Bad port format: $p" ;;
    esac
    out="$out$item"$'\n'
  done
  printf '%s' "$out" | jq -R . | jq -cs 'unique'
}

check_email() {
  case "$1" in
    *@*) ;;
    *) die "Give the friend's Tailscale login (like friend@example.com or name@github)" ;;
  esac
  [ "$1" != "$OWNER" ] || die "$1 is you (the owner); no friend rule needed"
}

# ---------- Subcommands ----------

cmd_invite() {
  local email="${1:-}" body
  load_token; load_self
  body="$(jq -cn --arg e "$email" '[{multiUse: false, allowExitNode: false} + (if $e == "" then {} else {email: $e} end)]')"
  api_ok POST "/device/$SELF_ID/device-invites" -H "Content-Type: application/json" --data-binary "$body"
  local url
  url="$(jq -r '.[0].inviteUrl // empty' "$TMP/body")"
  [ -n "$url" ] || die "API returned no inviteUrl: $(head -c 300 "$TMP/body")"
  ok "Created a single-use invite for $SELF_NAME (id $(jq -r '.[0].id' "$TMP/body"); expires if not accepted in 30 days)"
  [ -z "$email" ] || ok "Tailscale emailed the invite to ${email} (note: it can be accepted with any account; it is not tied to this address)"
  printf '\n  %s\n\n' "$url"
  echo "Once accepted, run: $(basename "$0") status   to see their login (acceptedBy), then: $(basename "$0") allow <login>"
}

cmd_allow() {
  [ "$#" -ge 1 ] || die "Usage: $(basename "$0") allow <email> [port...]"
  local email="$1"; shift
  load_token; load_self; check_email "$email"
  local ports
  # shellcheck disable=SC2086  # DEFAULT_PORTS is split on spaces on purpose
  ports="$(normalize_ports $DEFAULT_PORTS "$@")"
  if jq -e 'any(.[]; . == "*" or . == "tcp:22")' <<<"$ports" >/dev/null; then
    warn "You included SSH (22) or all ports; a guest should only need Screen Sharing. Sure? (Ctrl-C, or answer N below, to back out)"
  fi
  fetch_policy

  # Check whether the friend has accepted the share (a hint only, not a blocker: the rule may be written before they accept)
  if api GET "/device/$SELF_ID/device-invites"; then
    if ! jq -e --arg e "$email" 'any(.[]?; .acceptedBy.loginName == $e)' "$TMP/body" >/dev/null; then
      warn "No accepted invite for this machine by $email - the rule needs the login they accepted with (see $(basename "$0") status)"
    fi
  fi

  local tighten=0
  if jq -e "$JQ_DEFS has_allow_all" "$TMP/current.json" >/dev/null; then
    warn "The current policy has an allow-all rule (src \"*\" -> all ports): share recipients (autogroup:shared) can already reach every port here,"
    warn "so adding a friend rule restricts nothing. Suggested tightening: your member devices get full access + autogroup:shared only $(jq -r 'join(" ")' <<<"$SHARED_PORTS") + this friend's extra ports."
    if confirm "Replace the allow-all rule with the tightened policy?"; then
      tighten=1
    else
      warn "Not tightening: adding the friend rule anyway, but it restricts nothing while allow-all exists"
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
    # If this friend already has a rule, replace it in place (clean diff) and drop duplicates; otherwise append it
    | {src: [$e], dst: $a, ip: $p} as $new
    | (.grants // []) as $g
    | if any($g[]; friend_rule($e; $a)) then
        .grants = (reduce $g[] as $r ({out: [], done: false};
          if ($r | friend_rule($e; $a)) then
            (if .done then . else .out += [$new] | .done = true end)
          else .out += [$r] end) | .out)
      else .grants = $g + [$new] end
  ' "$TMP/current.json" >"$TMP/new.json"

  log "Friend $email -> ${SELF_NAME} ($(jq -r 'join(", ")' <<<"$SELF_ADDRS")): $(jq -r 'join(" ")' <<<"$ports")"
  write_policy
  echo "On their Mac, your friend opens Finder -> Go -> Connect to Server -> vnc://${SELF_NAME} and logs in with their own macOS account (see scripts/friend-mac.sh)."
}

cmd_revoke() {
  [ "$#" -eq 1 ] || die "Usage: $(basename "$0") revoke <email>"
  local email="$1"
  load_token; load_self
  fetch_policy
  local n
  n="$(jq --arg e "$email" --argjson a "$SELF_ADDRS" "$JQ_DEFS"'[.grants[]? | select(friend_rule($e; $a))] | length' "$TMP/current.json")"
  if [ "$n" = 0 ]; then
    warn "No friend rule for $email -> this machine in the policy"
  fi
  jq --arg e "$email" --argjson a "$SELF_ADDRS" "$JQ_DEFS"'
    if has("grants") then .grants = [.grants[] | select(friend_rule($e; $a) | not)] else . end
  ' "$TMP/current.json" >"$TMP/new.json"
  if jq -e --arg e "$email" '[.. | strings | select(. == $e)] | length > 0' "$TMP/new.json" >/dev/null; then
    warn "$email still appears elsewhere in the policy (groups/acls/ssh, etc.); left untouched - check the admin console"
  fi
  write_policy
  echo "Note: this only removed their extra ports; they are still a share recipient (autogroup:shared ports still work)."
  echo "To cut them off completely: https://login.tailscale.com/admin/machines -> ${SELF_NAME%%.*} -> Share... -> Revoke."
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
    | [.nodeId, (.name // .hostname), (.os // "?"), (.lastSeen // "never")] | @tsv
  ' "$TMP/body" >"$TMP/stale.tsv"
  if [ ! -s "$TMP/stale.tsv" ]; then
    ok "No stale offline $base / $base-* nodes"
    return 0
  fi
  log "These nodes are offline and not this machine (${SELF_ID}):"
  awk -F'\t' '{printf "  %-22s %-40s %-8s last seen %s\n", $1, $2, $3, $4}' "$TMP/stale.tsv"
  confirm "Delete them all? (a deleted machine must log in again to come back)" || die "Cancelled"
  local id name _os _seen
  while IFS="$(printf '\t')" read -r id name _os _seen; do
    if api DELETE "/device/$id"; then ok "Deleted $name"; else warn "Failed to delete $name: $(api_err)"; fi
  done <"$TMP/stale.tsv"
  if [ "${SELF_NAME%%.*}" != "$base" ]; then
    echo "This machine is now named ${SELF_NAME%%.*}. With the stale nodes gone you can rename it back to ${base} (Machines -> ... -> Edit machine name); then update TS_FQDN and chi serve to match."
  fi
}

cmd_status() {
  load_token; load_self
  log "Devices (this machine = ${SELF_NAME}, ${SELF_ID})"
  api_ok GET "/tailnet/-/devices"
  jq -r '.devices | sort_by(.name)[]
    | [ (if .connectedToControl then "online" else "offline" end),
        (.name // .hostname), (.addresses[0] // "-"), (.os // "?"), (.user // "-"),
        (if .isExternal then "shared-in" else "" end), (.lastSeen // "") ] | @tsv' "$TMP/body" |
    awk -F'\t' '{printf "  %-4s %-40s %-16s %-8s %-28s %s %s\n", $1, $2, $3, $4, $5, $6, $7}'

  echo
  log "Share invites for this machine"
  if api GET "/device/$SELF_ID/device-invites"; then
    if [ "$(jq 'length' "$TMP/body")" = 0 ]; then
      echo "  (none)"
    else
      jq -r '.[] | [ .id, (.created // "" | .[0:10]),
          (if .accepted then "accepted by " + (.acceptedBy.loginName // "?") else "pending" end),
          (.email // "-"), (if .accepted then "" else (.inviteUrl // "") end) ] | @tsv' "$TMP/body" |
        awk -F'\t' '{printf "  %-10s %s  %-40s email:%-24s %s\n", $1, $2, $3, $4, $5}'
    fi
  else
    warn "Could not read invites: $(api_err)"
  fi

  echo
  log "Friend-related rules in the policy"
  api_ok GET "/tailnet/-/acl" -H "Accept: application/json"
  cp "$TMP/body" "$TMP/current.json"
  if jq -e "$JQ_DEFS has_allow_all" "$TMP/current.json" >/dev/null; then
    warn "There is an allow-all rule: share recipients can reach every port here (allow will offer to tighten it)"
  fi
  jq -r --argjson a "$SELF_ADDRS" "$JQ_DEFS"'
    [.grants[]? | select(((.src // []) | has_el("autogroup:shared"))
                         or ((.dst // []) | length > 0 and ((. - $a) | length == 0)))]
    | if length == 0 then "  (none)" else .[] | "  " + (.src | join(",")) + "  ->  " + (.dst | join(",")) + "  :  " + ((.ip // ["*"]) | join(" ")) end
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
