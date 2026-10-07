# shellcheck shell=bash
# 公共函数。被 bin/chi 和 scripts/*.sh source，不单独执行。
#
# 注意：macOS 自带的是 bash 3.2（2007 年的版本，因为 GPLv3 授权问题苹果不升级）。
# 所以这里刻意不用：关联数组、mapfile、${var,,}、空数组的 "${a[@]}"（set -u 下会报错）。

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
  is_macos || die "这一步只能在 macOS 上跑（当前：$(uname -s)）"
}

# Homebrew 在 Apple Silicon 上装在 /opt/homebrew，非交互 shell（launchd）里 PATH 里没有它。
ensure_brew_path() {
  if [ -x /opt/homebrew/bin/brew ]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
  fi
  # OrbStack 把 docker CLI 放在这里
  if [ -d "$HOME/.orbstack/bin" ]; then
    PATH="$HOME/.orbstack/bin:$PATH"
  fi
  export PATH
}

load_env() {
  [ -f "$CHI_ROOT/.env" ] || die "没有 $CHI_ROOT/.env —— 先跑 'bin/chi init'"
  set -a
  # shellcheck disable=SC1091
  . "$CHI_ROOT/.env"
  set +a
  DATA_DIR="${DATA_DIR:-$HOME/srv/data}"
  export DATA_DIR
}

# 在 KEY=VALUE 文件里设置一个键（存在就替换，不存在就追加）。
# 用 awk 写临时文件，避开 BSD sed 和 GNU sed 的 -i 差异。
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
# 不用 `tr </dev/urandom | head`：head 提前退出会让 tr 收到 SIGPIPE，在 pipefail 下整个脚本被杀
rand_alnum() { openssl rand -base64 96 | LC_ALL=C tr -dc 'A-Za-z0-9' | cut -c1-"${1:-32}"; }

# 所有 stack 名（stacks/ 下的目录）
all_stacks() {
  local d
  for d in "$CHI_ROOT"/stacks/*/; do
    basename "$d"
  done
}

# .env 里 CHI_STACKS 启用的 stack；命令行给了就用命令行的
resolve_stacks() {
  if [ "$#" -gt 0 ]; then
    echo "$@"
  else
    echo "${CHI_STACKS:-core}"
  fi
}

stack_dir() {
  local d="$CHI_ROOT/stacks/$1"
  [ -d "$d" ] || die "没有这个 stack：$1（可选：$(all_stacks | tr '\n' ' ')）"
  echo "$d"
}

# 统一的 docker compose 调用：
#   -p chi-<stack>          项目名，容器/网络/卷都带这个前缀
#   --env-file .env         根目录的全局配置
#   --env-file stacks/x/.env 如果 stack 自己有（比如 Immich 的官方 .env）
#   -f compose.yaml [-f compose.override.yaml]
compose() {
  local stack="$1"; shift
  local dir; dir="$(stack_dir "$stack")"
  if [ ! -f "$dir/compose.yaml" ]; then
    if [ -x "$dir/fetch.sh" ]; then
      log "$stack: compose.yaml 不在仓库里，运行 fetch.sh 拉取上游版本"
      "$dir/fetch.sh"
    else
      die "$dir/compose.yaml 不存在"
    fi
  fi
  # 后面的 --env-file 覆盖前面的：根 .env 放最后，全局配置优先
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
  docker_ready || die "docker 连不上。OrbStack/Colima 起来了吗？（open -a OrbStack 或 colima start）"
}
