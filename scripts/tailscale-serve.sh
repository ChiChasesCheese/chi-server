#!/usr/bin/env bash
# 用 `tailscale serve` 把本机服务以 HTTPS 暴露给你的 tailnet（只有你登录了 Tailscale 的设备能访问）。
#
# 为什么用它而不是 Caddy/Nginx + 自己的域名：
#   - 证书 Tailscale 自动签发和续期（Let's Encrypt），零配置
#   - 不需要买域名、不需要开放任何端口、不需要 DNS
#   - 代价：地址是 https://<机器>.<tailnet>.ts.net:<端口>，不够好看；要好看见 docs/remote-access.md
#
# 注意：开 HTTPS 证书后，你的机器名会出现在公开的证书透明日志里（CT log）。只是名字，不是服务内容。
set -euo pipefail
. "$(dirname "$0")/lib.sh"
require_macos
ensure_brew_path
load_env

# stack → "HTTPS端口=本地端口" 列表。改端口记得同步 stacks/core/homepage/services.yaml
ports_for() {
  case "$1" in
    core)       echo "443=3000 8001=3001 8002=8080" ;;
    ai)         echo "8003=3080" ;;
    automation) echo "8004=5678" ;;
    vault)      echo "8005=8222" ;;
    photos)     echo "8006=2283" ;;
    media)      echo "8009=8096 8010=8081" ;;
    *)          echo "" ;;
  esac
}

action="${1:-apply}"
case "$action" in
  apply)
    [ -n "${TS_FQDN:-}" ] || die ".env 里 TS_FQDN 为空。先 chi bootstrap tailscale，再 chi init"
    for s in $(resolve_stacks); do
      for pair in $(ports_for "$s"); do
        https="${pair%%=*}"; local_port="${pair##*=}"
        sudo_ts serve --bg --https="$https" "http://127.0.0.1:$local_port" >/dev/null
        ok "$s  https://$TS_FQDN$( [ "$https" = 443 ] || printf ':%s' "$https")  →  127.0.0.1:$local_port"
      done
    done
    # 接入页面 + PAC（chi onboard 生成的静态文件）
    if [ -f "$DATA_DIR/share/index.html" ]; then
      sudo_ts serve --bg --https=8008 "$DATA_DIR/share" >/dev/null
      ok "share  https://$TS_FQDN:8008  →  $DATA_DIR/share（接入指南）"
    fi
    # mihomo 面板（装了 chi proxy 才有）
    if [ -f "$(brew --prefix)/etc/mihomo/config.yaml" ]; then
      sudo_ts serve --bg --https=8007 "http://127.0.0.1:9090" >/dev/null
      ok "proxy  https://$TS_FQDN:8007/ui  →  127.0.0.1:9090（面板里后端填 https://$TS_FQDN:8007，密钥是 .env 的 CLASH_SECRET）"
    fi
    ;;
  status) tailscale serve status ;;
  reset)  sudo_ts serve reset && ok "已清空所有 serve 规则" ;;
  *) die "用法: chi serve [apply|status|reset]" ;;
esac
