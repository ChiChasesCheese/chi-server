# shellcheck shell=bash
# Shared helpers. Sourced by bin/chi and scripts/*.sh; never executed directly.
#
# Portability: macOS ships bash 3.2 (2007; Apple won't ship GPLv3 bash). So, deliberately:
# no associative arrays, no mapfile, no ${var,,}, no "${a[@]}" on possibly-empty arrays (set -u).

CHI_ROOT="${CHI_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
export CHI_ROOT

if [ -t 1 ]; then
  C_B=$'\033[1;34m'; C_G=$'\033[1;32m'; C_Y=$'\033[1;33m'; C_R=$'\033[1;31m'; C_0=$'\033[0m'
else
  C_B=""; C_G=""; C_Y=""; C_R=""; C_0=""
fi

log()  { printf '%s==>%s %s\n' "$C_B" "$C_0" "$*"; }
ok()   { printf '%s ✓%s %s\n' "$C_G" "$C_0" "$*"; }
warn() { printf '%s !%s %s\n' "$C_Y" "$C_0" "$*" >&2; }
die()  { printf '%s ✗%s %s\n' "$C_R" "$C_0" "$*" >&2; exit 1; }

is_macos() { [ "$(uname -s)" = "Darwin" ]; }
have()     { command -v "$1" >/dev/null 2>&1; }

require_macos() {
  is_macos || die "This step only runs on macOS (current: $(uname -s))"
}

# Homebrew lives in /opt/homebrew on Apple Silicon, which non-interactive shells (launchd, ssh -c) don't have on PATH.
ensure_brew_path() {
  if [ -x /opt/homebrew/bin/brew ]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
  fi
  # OrbStack installs the docker CLI here
  if [ -d "$HOME/.orbstack/bin" ]; then
    PATH="$HOME/.orbstack/bin:$PATH"
  fi
  export PATH
}

load_env() {
  [ -f "$CHI_ROOT/.env" ] || die "Missing $CHI_ROOT/.env - run 'bin/chi init' first"
  set -a
  # shellcheck disable=SC1091
  . "$CHI_ROOT/.env"
  set +a
  DATA_DIR="${DATA_DIR:-$HOME/srv/data}"
  export DATA_DIR
}

# Set KEY=VALUE in a dotenv-style file (replace if present, append otherwise).
# Writes through awk + a temp file to avoid BSD vs GNU `sed -i` differences.
set_kv() {
  local file="$1" key="$2" value="$3" tmp
  tmp="$(mktemp)"
  if [ -f "$file" ] && grep -q "^${key}=" "$file"; then
    awk -v k="$key" -v v="$value" 'BEGIN{FS=OFS="="} $1==k {print k "=" v; next} {print}' "$file" >"$tmp"
  else
    { [ -f "$file" ] && cat "$file"; printf '%s=%s\n' "$key" "$value"; } >"$tmp"
  fi
  mv "$tmp" "$file"
}

get_kv() {
  local file="$1" key="$2"
  [ -f "$file" ] || return 0
  { grep "^${key}=" "$file" || true; } | tail -n1 | cut -d= -f2- | sed -e 's/^"//' -e 's/"$//'
}

rand_hex() { openssl rand -hex "${1:-32}"; }
# Not `tr </dev/urandom | head`: head exits early, tr gets SIGPIPE, and pipefail kills the script.
rand_alnum() { openssl rand -base64 96 | LC_ALL=C tr -dc 'A-Za-z0-9' | cut -c1-"${1:-32}"; }

# Render a template: replace every __NAME__ with the value of env var TPL_NAME (literal replacement).
#   TPL_FOO=bar TPL_BAZ=qux render_tmpl file.tmpl > out
# Not sed (& / # are special) and not awk -v (it interprets escapes like \b); values go through ENVIRON verbatim.
render_tmpl() {
  awk '
    function rep(s, from, to,   i, out) {
      out = ""
      while ((i = index(s, from)) > 0) { out = out substr(s, 1, i - 1) to; s = substr(s, i + length(from)) }
      return out s
    }
    BEGIN { n = 0; for (k in ENVIRON) if (k ~ /^TPL_/) { n++; key[n] = "__" substr(k, 5) "__"; val[n] = ENVIRON[k] } }
    { l = $0; for (j = 1; j <= n; j++) l = rep(l, key[j], val[j]); print l }' "$1"
}

lan_ip() { ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || echo ""; }

# chi runs the Homebrew tailscaled as a system daemon (online at boot, before anyone logs in). If Tailscale.app
# is also installed, the CLI without --socket talks to the app's instance instead - often a different, stopped
# node - so on macOS every call pins the daemon's socket.
TS_SOCK=/var/run/tailscaled.socket
if is_macos && [ -S "$TS_SOCK" ]; then
  tailscale()  { command tailscale --socket="$TS_SOCK" "$@"; }
  sudo_ts()    { sudo "$(type -P tailscale)" --socket="$TS_SOCK" "$@"; }
else
  sudo_ts()    { sudo "$(type -P tailscale)" "$@"; }
fi
ts_ip()  { tailscale ip -4 2>/dev/null | head -n1 || true; }

# Is auto-login actually in effect? `autoLoginUser` alone is not enough: when the password never made it into
# /etc/kcpassword the preference is set but the Mac still stops at the login window. Trust `sysadminctl` + the
# kcpassword file. Prints the user when effective, nothing otherwise.
autologin_effective() {
  local u
  u="$(defaults read /Library/Preferences/com.apple.loginwindow autoLoginUser 2>/dev/null || true)"
  [ -n "$u" ] && [ -e /etc/kcpassword ] && ! sysadminctl -autologin status 2>&1 | grep -q "is OFF" && echo "$u"
  return 0
}

# ---------- stacks ----------
# A stack is a directory under stacks/ with a compose.yaml (or a fetch.sh that produces one) and an optional
# stack.conf manifest:
#   DESCRIPTION="..."                    one line, shown by `chi stacks`
#   SERVE="443=3000 8001=3001"           Tailscale HTTPS exposure, <https_port>=<local_port> pairs

all_stacks() {
  local d
  for d in "$CHI_ROOT"/stacks/*/; do
    basename "$d"
  done
}

# Stacks to act on: the ones given on the command line, else CHI_STACKS from .env
resolve_stacks() {
  if [ "$#" -gt 0 ]; then
    echo "$@"
  else
    echo "${CHI_STACKS:-core}"
  fi
}

stack_dir() {
  local d="$CHI_ROOT/stacks/$1"
  [ -d "$d" ] || die "Unknown stack: $1 (available: $(all_stacks | tr '\n' ' '))"
  echo "$d"
}

# Read one key from a stack's manifest without polluting the caller's environment.
stack_conf() {
  local stack="$1" key="$2" f="$CHI_ROOT/stacks/$1/stack.conf"
  [ -f "$f" ] || return 0
  # shellcheck disable=SC1090,SC2034
  ( DESCRIPTION=""; SERVE=""; . "$f"; eval "printf '%s\n' \"\${$key:-}\"" )
}

# Unified docker compose call:
#   -p chi-<stack>               project name; containers/networks/volumes get this prefix
#   --env-file .env              global configuration (repo root)
#   --env-file stacks/x/.env     stack-local env if present (e.g. Immich's upstream .env)
#   -f compose.yaml [-f compose.override.yaml]
compose() {
  local stack="$1"; shift
  local dir; dir="$(stack_dir "$stack")"
  if [ ! -f "$dir/compose.yaml" ]; then
    if [ -x "$dir/fetch.sh" ]; then
      log "$stack: compose.yaml is not vendored; running fetch.sh to pull the upstream version"
      "$dir/fetch.sh"
    else
      die "$dir/compose.yaml not found"
    fi
  fi
  # A later --env-file overrides an earlier one: the root .env goes last so global settings win.
  set -- -p "chi-$stack" --env-file "$CHI_ROOT/.env" "$@"
  if [ -f "$dir/.env" ]; then
    set -- --env-file "$dir/.env" "$@"
  fi
  set -- -f "$dir/compose.yaml" "$@"
  if [ -f "$dir/compose.override.yaml" ]; then
    set -- -f "$dir/compose.yaml" -f "$dir/compose.override.yaml" "${@:3}"
  fi
  docker compose "$@"
}

docker_ready() {
  have docker && docker info >/dev/null 2>&1
}

require_docker() {
  ensure_brew_path
  docker_ready || die "Cannot reach docker. Is OrbStack/Colima running? (open -a OrbStack, or colima start)"
}
