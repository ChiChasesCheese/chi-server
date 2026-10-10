#!/usr/bin/env bash
# chi up public 之前：有 CF_TUNNEL_TOKEN 才启用 cloudflared（compose profile "tunnel"）
set -euo pipefail
. "$(dirname "$0")/../../scripts/lib.sh"
load_env

env_file="$(dirname "$0")/.env"
if [ -n "${CF_TUNNEL_TOKEN:-}" ]; then
  profiles=tunnel
  ok "Cloudflare Tunnel 已配置：启动 cloudflared（公网入口状态看 Cloudflare 后台 Networking → Tunnels）"
else
  profiles=
  warn ".env 里 CF_TUNNEL_TOKEN 为空：只启动示例应用，不连 Cloudflare（配置步骤见 docs/public.md）"
  # 之前填过 token、现在清空了：profile 不启用时 compose 不会管它，这里显式移除，确保真的下线
  if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx chi-cloudflared; then
    docker rm -f chi-cloudflared >/dev/null
    ok "已移除旧的 chi-cloudflared 容器（公网入口已关闭）"
  fi
fi
{
  echo "# 由 stacks/public/pre-up.sh 生成，别手改"
  echo "COMPOSE_PROFILES=${profiles}"
} >"$env_file"
