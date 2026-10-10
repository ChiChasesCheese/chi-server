#!/usr/bin/env bash
# chi up media 之前：建目录；生成 MeTube 的 yt-dlp 选项（有回国代理就用上）
set -euo pipefail
. "$(dirname "$0")/../../scripts/lib.sh"
load_env
MEDIA_DIR="${MEDIA_DIR:-$DATA_DIR/media}"
mkdir -p "$MEDIA_DIR/Downloads" "$MEDIA_DIR/Keep" "$MEDIA_DIR/Movies" "$MEDIA_DIR/TV" \
  "$DATA_DIR/jellyfin/config" "$DATA_DIR/jellyfin/cache" "$DATA_DIR/metube"

env_file="$(dirname "$0")/.env"
port="${CLASH_PORT:-7890}"
if nc -z 127.0.0.1 "$port" >/dev/null 2>&1; then
  # 所有下载都经过 mihomo：B 站等走回国，YouTube 等按规则直连
  opts="{\"proxy\": \"http://host.docker.internal:$port\"}"
  ok "MeTube 将通过 mihomo 下载（B 站大陆限定内容可用）"
else
  opts="{}"
  warn "mihomo 没在跑：MeTube 直连下载（B 站大陆限定内容会失败；需要的话先 chi proxy install）"
fi
{
  echo "# 由 stacks/media/pre-up.sh 生成，别手改"
  echo "MEDIA_DIR=$MEDIA_DIR"
  echo "METUBE_YTDL_OPTIONS='$opts'"
} >"$env_file"
