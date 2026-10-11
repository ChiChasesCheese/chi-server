#!/usr/bin/env bash
# Split-routing proxy back into mainland China: mihomo (the Clash Meta core), running natively on the Mac.
# Only Bilibili / iQIYI / Youku / Tencent Video / NetEase Music etc. go through your China VPN nodes; everything
# else goes direct.
#
#   chi proxy install   install mihomo, render the config, start it, allow it through the firewall
#   chi proxy apply     re-render the config and restart after editing .env or the template
#   chi proxy test      verify: does Bilibili see your IP as China?
#   chi proxy status    service status + current node
#   chi proxy logs      follow the log
#   chi proxy firewall  re-allow through the firewall after a brew upgrade of mihomo (update runs this)
#   chi proxy uninstall stop and remove
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
  # brew binaries are ad-hoc signed, so "automatically allow signed software" doesn't cover them; add it by hand.
  # The path contains the version (Cellar), so it has to be re-added after every brew upgrade.
  local bin; bin="$(realpath "$(brew --prefix)/opt/mihomo/bin/mihomo")"
  local fw=/usr/libexec/ApplicationFirewall/socketfilterfw
  sudo "$fw" --add "$bin" >/dev/null
  sudo "$fw" --unblockapp "$bin" >/dev/null
  ok "Firewall allows $bin"
}

apply() {
  [ -n "${CLASH_SUBSCRIPTION_URL:-}" ] || die "CLASH_SUBSCRIPTION_URL is empty in .env: set it to your China VPN's Clash subscription URL"
  [ -n "${CLASH_SECRET:-}" ] || die "CLASH_SECRET is empty: run chi init"
  local dir; dir="$(conf_dir)"
  mkdir -p "$dir"
  render >"$dir/config.yaml.new"
  chmod 600 "$dir/config.yaml.new"
  mv "$dir/config.yaml.new" "$dir/config.yaml"
  # -t validates without starting. The first run downloads geosite data, which can take a few seconds
  mihomo -t -d "$dir" >/dev/null || { mihomo -t -d "$dir"; die "Config validation failed"; }
  brew services restart mihomo >/dev/null
  ok "mihomo started: proxy $(lan_ip):${PORT} (HTTP/SOCKS5), dashboard (after chi serve) https://${TS_FQDN}:8007/ui"
}

case "${1:-status}" in
  install)
    have mihomo || brew install mihomo
    apply
    firewall_allow
    log "Waiting 5s for node latency tests, then self-checking"
    sleep 5
    "$0" test || true
    ;;
  apply) apply ;;
  firewall) firewall_allow ;;
  test)
    api=https://api.bilibili.com/x/web-interface/zone
    # Bilibili reports .country in Chinese; mainland China is "\u4e2d\u56fd". Spelled as UTF-8 bytes to keep this file
    # ASCII (bash 3.2's $'...' has \x but not \u).
    cn=$'\xe4\xb8\xad\xe5\x9b\xbd'
    direct="$(curl -fsS --max-time 8 "$api" | jq -r '.data | "\(.country) \(.province) \(.addr)"' 2>/dev/null || echo "failed")"
    via="$(curl -fsS --max-time 15 -x "http://127.0.0.1:$PORT" "$api" | jq -r '.data | "\(.country) \(.province) \(.addr)"' 2>/dev/null || echo "failed")"
    log "Bilibili sees you - direct:    $direct"
    log "Bilibili sees you - via proxy: $via"
    case "$via" in
      "$cn"*) ok "China split routing works" ;;
      *) die "Proxy exit is not in China. Check: is the subscription valid, does CLASH_CN_FILTER match any nodes (chi proxy status)" ;;
    esac
    ;;
  status)
    brew services info mihomo 2>/dev/null | head -n 4 || true
    curl -fsS --max-time 3 -H "Authorization: Bearer ${CLASH_SECRET:-}" http://127.0.0.1:9090/proxies/CN \
      | jq -r '"CN group node: \(.now)   candidates: \(.all | length)"' 2>/dev/null \
      || warn "API not responding (mihomo not running? or no nodes left after filtering)"
    ;;
  logs) tail -n 100 -f "$(brew --prefix)/var/log/mihomo.log" ;;
  uninstall)
    brew services stop mihomo >/dev/null 2>&1 || true
    rm -f "$(conf_dir)/config.yaml"
    ok "Stopped and removed the config (brew uninstall mihomo removes it completely)"
    ;;
  *) die "Usage: chi proxy [install|apply|test|status|logs|firewall|uninstall]" ;;
esac
