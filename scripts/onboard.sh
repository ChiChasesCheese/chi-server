#!/usr/bin/env bash
# 生成给自己和朋友的接入页面 + PAC，放到 $DATA_DIR/share，由 `chi serve` 以 https://<TS_FQDN>:8008 提供。
# 同时打印一段可以直接发微信/iMessage 的邀请文字。
#
# 页面里不含任何密码/订阅；PAC 里只有 Mac mini 的 Tailscale IP（只有 tailnet 内可达）。
set -euo pipefail
. "$(dirname "$0")/lib.sh"
ensure_brew_path
load_env

[ -n "${TS_FQDN:-}" ] || die "TS_FQDN 为空：先 chi bootstrap tailscale，再 chi init"
tsip="$(ts_ip)"; [ -n "$tsip" ] || die "拿不到 Tailscale IP（tailscale status 看看）"
host="${TS_FQDN%%.*}"
out="$DATA_DIR/share"
mkdir -p "$out"

today="$(date '+%Y-%m-%d')"
export TPL_FQDN="$TS_FQDN" TPL_TS_IP="$tsip" TPL_PORT="${CLASH_PORT:-7890}" TPL_HOST="$host" \
  TPL_MEDIA_MAX_GB="${MEDIA_MAX_GB:-60}" TPL_GENERATED="$today"
render_tmpl "$CHI_ROOT/config/onboarding/index.html.tmpl" >"$out/index.html"
render_tmpl "$CHI_ROOT/config/onboarding/chi.pac.tmpl" >"$out/chi.pac"
ok "已生成 $out/index.html 和 chi.pac"

if is_macos; then "$CHI_ROOT/scripts/tailscale-serve.sh" apply >/dev/null && ok "已通过 chi serve 发布到 https://$TS_FQDN:8008"; fi

cat <<MSG

──────── 管理员要做的（每邀请一个朋友做一次）────────
 1. https://login.tailscale.com/admin/machines → $host → 「…」→ Share… → 复制邀请链接
    （第一次的话：按 docs/onboarding.md 配一下 ACL，限制朋友只能访问哪些端口）
 2. Jellyfin 后台 → 控制台 → 用户 → 新建一个他的账号（可以只给部分媒体库）
 3. 把下面这段发给他：

──────── 复制给朋友 ────────
嗨！我家服务器的接入方式：
1) 手机/电脑装 Tailscale（App Store / Play 商店 / tailscale.com/download），随便用个账号登录
2) 打开这个邀请链接并接受：<把第 1 步复制的链接贴在这里>
3) 保持 Tailscale 连接，打开 https://$TS_FQDN:8008 —— 里面有 iPhone / Mac 怎么设置、怎么看片、怎么看 B 站大陆内容
Jellyfin 账号：<用户名> / <初始密码>（登录后改掉）
──────────────────────────
MSG
