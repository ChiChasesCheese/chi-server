#!/usr/bin/env bash
# 生成/补全 .env。幂等：已有的值不动，只填空的和 CHANGE_ME。
set -euo pipefail
. "$(dirname "$0")/lib.sh"
ensure_brew_path

ENV="$CHI_ROOT/.env"

if [ ! -f "$ENV" ]; then
  cp "$CHI_ROOT/.env.example" "$ENV"
  chmod 600 "$ENV"
  ok "已从 .env.example 创建 .env"
fi

# 仓库升级后 .env.example 可能多了新键：补进 .env（用模板里的默认值），已有的不动
while IFS= read -r line; do
  key="${line%%=*}"
  if ! grep -q "^${key}=" "$ENV"; then
    printf '%s\n' "$line" >>"$ENV"
    ok "补上新配置项 $key"
  fi
done <<EOF
$(grep -E '^[A-Z_][A-Z0-9_]*=' "$CHI_ROOT/.env.example")
EOF

fill_if_empty() {
  local key="$1" value="$2" cur
  cur="$(get_kv "$ENV" "$key")"
  if [ -z "$cur" ] || printf '%s' "$cur" | grep -q CHANGE_ME; then
    set_kv "$ENV" "$key" "$value"
    ok "$key 已设置"
  fi
}

fill_if_empty DATA_DIR "$HOME/srv/data"
fill_if_empty MEDIA_DIR "$HOME/srv/data/media"
fill_if_empty RESTIC_PASSWORD_FILE "$HOME/.config/chi/restic-password"
fill_if_empty OPEN_WEBUI_SECRET_KEY "$(rand_hex 32)"
fill_if_empty N8N_ENCRYPTION_KEY "$(rand_hex 32)"
fill_if_empty CLASH_SECRET "$(rand_hex 16)"

if is_macos && [ -L /etc/localtime ]; then
  tz="$(readlink /etc/localtime | sed 's#.*/zoneinfo/##')"
  [ -n "$tz" ] && set_kv "$ENV" TZ "$tz" && ok "TZ=${tz}（读自系统）"
fi

if have tailscale; then
  fqdn="$(tailscale status --json 2>/dev/null | jq -r '.Self.DNSName // empty' 2>/dev/null | sed 's/\.$//' || true)"
  if [ -n "${fqdn:-}" ]; then
    set_kv "$ENV" TS_FQDN "$fqdn"
    ok "TS_FQDN=$fqdn"
  else
    warn "Tailscale 还没登录，TS_FQDN 先空着（跑完 chi bootstrap tailscale 后再 chi init 一次）"
  fi
fi

# restic 密码文件
pwfile="$(get_kv "$ENV" RESTIC_PASSWORD_FILE)"
if [ ! -f "$pwfile" ]; then
  mkdir -p "$(dirname "$pwfile")"
  rand_alnum 40 >"$pwfile"
  chmod 600 "$pwfile"
  warn "已生成 restic 密码：$pwfile"
  warn "→ 现在就把它的内容存进你的密码管理器。机器挂了没有这个密码，备份就是一堆随机字节。"
fi

mkdir -p "$(get_kv "$ENV" DATA_DIR)"
ok ".env 就绪：${ENV}（改完记得 chi up）"
