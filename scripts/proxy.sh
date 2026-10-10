#!/usr/bin/env bash
# 「回国」分流代理：mihomo（Clash Meta 内核），原生跑在 Mac 上。
# 只有 B 站 / 爱奇艺 / 优酷 / 腾讯视频 / 网易云 等走你的大陆 VPN 节点，其他全部直连。
#
#   chi proxy install   安装 mihomo、生成配置、启动、放行防火墙
#   chi proxy apply     改了 .env 或模板后重新生成配置并重启
#   chi proxy test      验证：B 站看到的你的 IP 是不是「中国」
#   chi proxy status    服务状态 + 当前节点
#   chi proxy logs      看日志
#   chi proxy firewall  brew 升级 mihomo 后重新放行防火墙（update 会自动跑）
#   chi proxy uninstall 停止并移除
set -euo pipefail
. "$(dirname "$0")/lib.sh"
require_macos
ensure_brew_path
load_env

PORT="${CLASH_PORT:-7890}"
TMPL="$CHI_ROOT/config/mihomo/config.yaml.tmpl"

conf_dir() { echo "$(brew --prefix)/etc/mihomo"; }

render() {
  TPL_SUB_URL="$CLASH_SUBSCRIPTION_URL" TPL_CN_FILTER="${CLASH_CN_FILTER:-.*}" \
  TPL_SECRET="$CLASH_SECRET" TPL_PORT="$PORT" render_tmpl "$TMPL"
}

firewall_allow() {
  # brew 的二进制是 ad-hoc 签名，“自动放行已签名应用”管不到它，得手动加。
  # 路径带版本号（Cellar），所以每次 brew 升级后要重新加一次。
  local bin; bin="$(realpath "$(brew --prefix)/opt/mihomo/bin/mihomo")"
  local fw=/usr/libexec/ApplicationFirewall/socketfilterfw
  sudo "$fw" --add "$bin" >/dev/null
  sudo "$fw" --unblockapp "$bin" >/dev/null
  ok "防火墙已放行 $bin"
}

apply() {
  [ -n "${CLASH_SUBSCRIPTION_URL:-}" ] || die ".env 里 CLASH_SUBSCRIPTION_URL 为空：填你回国 VPN 的 Clash 订阅地址"
  [ -n "${CLASH_SECRET:-}" ] || die "CLASH_SECRET 为空：跑一次 chi init"
  local dir; dir="$(conf_dir)"
  mkdir -p "$dir"
  render >"$dir/config.yaml.new"
  chmod 600 "$dir/config.yaml.new"
  mv "$dir/config.yaml.new" "$dir/config.yaml"
  # -t 只校验不启动。第一次会下载 geosite 数据，可能要几秒
  mihomo -t -d "$dir" >/dev/null || { mihomo -t -d "$dir"; die "配置校验失败"; }
  brew services restart mihomo >/dev/null
  ok "mihomo 已启动：代理 $(lan_ip):${PORT}（HTTP/SOCKS5），面板 chi serve 后 https://$TS_FQDN:8007/ui"
}

case "${1:-status}" in
  install)
    have mihomo || brew install mihomo
    apply
    firewall_allow
    log "等 5 秒让节点测速完成，然后自检"
    sleep 5
    "$0" test || true
    ;;
  apply) apply ;;
  firewall) firewall_allow ;;
  test)
    api=https://api.bilibili.com/x/web-interface/zone
    direct="$(curl -fsS --max-time 8 "$api" | jq -r '.data | "\(.country) \(.province) \(.addr)"' 2>/dev/null || echo "失败")"
    via="$(curl -fsS --max-time 15 -x "http://127.0.0.1:$PORT" "$api" | jq -r '.data | "\(.country) \(.province) \(.addr)"' 2>/dev/null || echo "失败")"
    log "B 站眼中的你 —— 直连：$direct"
    log "B 站眼中的你 —— 经代理：$via"
    case "$via" in
      中国*) ok "回国分流正常" ;;
      *) die "代理出口不是中国。检查：订阅是否有效、CLASH_CN_FILTER 是否匹配到节点（chi proxy status）" ;;
    esac
    ;;
  status)
    brew services info mihomo 2>/dev/null | head -n 4 || true
    curl -fsS --max-time 3 -H "Authorization: Bearer ${CLASH_SECRET:-}" http://127.0.0.1:9090/proxies/CN \
      | jq -r '"CN 组当前节点：\(.now)   候选：\(.all | length) 个"' 2>/dev/null \
      || warn "API 没响应（mihomo 没跑？或者过滤后没有节点）"
    ;;
  logs) tail -n 100 -f "$(brew --prefix)/var/log/mihomo.log" ;;
  uninstall)
    brew services stop mihomo >/dev/null 2>&1 || true
    rm -f "$(conf_dir)/config.yaml"
    ok "已停止并删除配置（brew uninstall mihomo 可彻底移除）"
    ;;
  *) die "用法: chi proxy [install|apply|test|status|logs|firewall|uninstall]" ;;
esac
