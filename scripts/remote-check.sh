#!/usr/bin/env bash
# 端到端检查：在“控制机”（你的 MacBook）上跑，从用户视角验证 mini 上的一切。
#   chi remote-check [ssh-host]     默认 ssh host = chi-mini
# 检查：Tailscale 连通与直连、SSH、公网入口、tailnet 内每个服务、局域网 Jellyfin、mini 上的 chi doctor。
# 不需要本机有 .env；TS_FQDN / PUBLIC_DOMAIN 从 mini 上读。
set -uo pipefail
. "$(dirname "$0")/lib.sh"

host="${1:-chi-mini}"
fails=0
bad() { warn "$*"; fails=$((fails + 1)); }
code() { curl -s -o /dev/null -m 8 -w '%{http_code}' "$1" 2>/dev/null || true; }

# 用 type -P 找真正的可执行文件：lib.sh 在 mini 上把 tailscale 定义成了带 --socket 的函数，控制机上不适用
TSBIN="$(type -P tailscale || echo /Applications/Tailscale.app/Contents/MacOS/Tailscale)"

log "Tailscale"
if out="$("$TSBIN" ping -c 3 "$host" 2>&1)"; then
  last="$(printf '%s\n' "$out" | tail -1)"
  case "$last" in
    *DERP*) warn "走中继：${last}（能用，但慢；见 docs/remote-access.md 端口转发）" ;;
    *pong*) ok "$last" ;;
    *) bad "tailscale ping 异常：${last}" ;;
  esac
else
  bad "tailscale ping 失败（本机 Tailscale 没开？）"
fi

log "SSH"
if ssh -o BatchMode=yes -o ConnectTimeout=8 "$host" true 2>/dev/null; then
  ok "ssh ${host} 免密可用"
else
  bad "ssh ${host} 失败（Tailscale / ~/.ssh/config / authorized_keys）"
  exit "$fails"
fi

# shellcheck disable=SC2029  # $1 有意在本机展开成键名
env_get() { ssh "$host" "grep '^$1=' ~/chi-service/.env | cut -d= -f2- | tr -d \"'\\\"\"" 2>/dev/null; }
TS="$(env_get TS_FQDN)"
PUB="$(env_get PUBLIC_DOMAIN)"
STACKS="$(env_get CHI_STACKS)"

if [ -n "$PUB" ] && case " $STACKS " in *" public "*) true ;; *) false ;; esac; then
  log "公网（Cloudflare Tunnel）"
  c="$(code "https://$PUB")"
  [ "$c" = 200 ] && ok "https://${PUB} → ${c}" || bad "https://${PUB} → ${c}（530/1033 = cloudflared 没连上，多半是 mini 没登录）"
fi

log "tailnet 服务（https://${TS}）"
check() {  # stack 端口 名字
  case " $STACKS " in *" $1 "*) ;; *) return 0 ;; esac
  local url="https://$TS$2" c
  c="$(code "$url")"
  case "$c" in
    200|301|302|307|401) ok "$3 ${url} → ${c}" ;;
    *) bad "$3 ${url} → ${c}" ;;
  esac
}
check core  ""      首页
check core  :8001   "Uptime Kuma"
check core  :8002   Dozzle
check ai    :8003   "Open WebUI"
check media :8009   Jellyfin
check media :8010   MeTube
c="$(code "https://$TS:8008")"
[ "$c" = 200 ] && ok "接入页 https://${TS}:8008 → ${c}" || warn "接入页 :8008 → ${c}（没跑过 chi onboard？）"

if case " $STACKS " in *" media "*) true ;; *) false ;; esac; then
  log "局域网 Jellyfin（电视盒子用）"
  ip="$(ssh "$host" 'ipconfig getifaddr en0 || ipconfig getifaddr en1' 2>/dev/null)"
  c="$(code "http://$ip:8096/")"
  case "$c" in 200|302) ok "http://${ip}:8096 → ${c}" ;; *) warn "http://${ip}:8096 → ${c}（不在同一局域网时这条失败是正常的）" ;; esac
fi

log "mini 上的 chi doctor"
if ssh "$host" 'cd ~/chi-service && PATH=/opt/homebrew/bin:$HOME/.orbstack/bin:$PATH bin/chi doctor' >/dev/null 2>&1; then
  ok "doctor 全部正常"
else
  bad "doctor 有问题：ssh ${host} 'cd ~/chi-service && bin/chi doctor'"
fi

echo
if [ "$fails" -eq 0 ]; then ok "端到端全部通过"; else warn "${fails} 项失败"; fi
exit "$fails"
