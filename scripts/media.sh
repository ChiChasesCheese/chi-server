#!/usr/bin/env bash
# 媒体库管理。
#   chi fetch <url> [文件夹]    交给 MeTube 下载（YouTube / B 站 / 上千个站点，yt-dlp 支持的都行）
#   chi media usage             看占用
#   chi media clean [--dry-run] Downloads/ 超过 MEDIA_MAX_GB 时，从最旧的文件开始删
#   chi media scan              让 Jellyfin 立刻重新扫描媒体库
set -euo pipefail
. "$(dirname "$0")/lib.sh"
ensure_brew_path
load_env
MEDIA_DIR="${MEDIA_DIR:-$DATA_DIR/media}"
MAX_GB="${MEDIA_MAX_GB:-60}"
DL="$MEDIA_DIR/Downloads"

kb_of() { du -sk "$1" 2>/dev/null | awk '{print $1}'; }

# 列出 Downloads 下的文件：“修改时间 路径”，最旧的在前。跳过 MeTube 的临时目录和隐藏文件
list_oldest_first() {
  if is_macos; then
    find "$DL" -type f ! -path '*/.*' -exec stat -f '%m %N' {} + 2>/dev/null
  else
    find "$DL" -type f ! -path '*/.*' -exec stat -c '%Y %n' {} + 2>/dev/null
  fi | sort -n
}

action="${1:-usage}"; [ "$#" -gt 0 ] && shift
case "$action" in
  fetch)
    url="${1:-}"; [ -n "$url" ] || die "用法: chi fetch <url> [文件夹]"
    folder="${2:-}"
    quality="${MEDIA_MAX_HEIGHT:-1080}"
    body="$(jq -nc --arg u "$url" --arg q "$quality" --arg f "$folder" \
      '{url: $u, quality: $q} + (if $f == "" then {} else {folder: $f} end)')"
    resp="$(curl -fsS -X POST -H 'Content-Type: application/json' -d "$body" http://127.0.0.1:8081/add)" \
      || die "MeTube 没响应（chi up media 了吗？）"
    case "$resp" in *'"ok"'*) ok "已加入下载队列（${quality}p）：$url" ;; *) die "MeTube 返回：$resp" ;; esac
    ;;
  usage)
    [ -d "$MEDIA_DIR" ] || die "$MEDIA_DIR 不存在（chi up media 会创建）"
    for d in Downloads Keep Movies TV; do
      [ -d "$MEDIA_DIR/$d" ] && printf '  %-10s %s\n' "$d" "$(du -sh "$MEDIA_DIR/$d" 2>/dev/null | cut -f1)"
    done
    log "Downloads 上限 ${MAX_GB}G（MEDIA_MAX_GB）；系统盘剩余 $(df -h "$MEDIA_DIR" | awk 'NR==2 {print $4}')"
    ;;
  clean)
    dry=0; [ "${1:-}" = "--dry-run" ] && dry=1
    [ -d "$DL" ] || exit 0
    limit_kb=$((MAX_GB * 1024 * 1024))
    used_kb="$(kb_of "$DL")"
    if [ "$used_kb" -le "$limit_kb" ]; then
      ok "Downloads $((used_kb / 1024 / 1024))G ≤ 上限 ${MAX_GB}G，不用清理"; exit 0
    fi
    log "Downloads $((used_kb / 1024 / 1024))G > 上限 ${MAX_GB}G，从最旧的开始删（Keep/ Movies/ TV/ 不受影响）"
    list_oldest_first | while read -r _mtime path; do
      [ "$used_kb" -le "$limit_kb" ] && break
      size_kb="$(kb_of "$path")"
      if [ "$dry" = 1 ]; then echo "  [dry-run] 会删 $path"; else rm -f "$path"; echo "  删除 $path"; fi
      used_kb=$((used_kb - size_kb))
    done
    # 清掉空目录（频道文件夹）
    [ "$dry" = 1 ] || find "$DL" -mindepth 1 -type d -empty ! -path '*/.*' -delete 2>/dev/null || true
    ok "清理完成"
    ;;
  scan)
    # Jellyfin 默认每 12 小时扫描一次；新下载想马上看到就跑这个
    [ -n "${JELLYFIN_API_KEY:-}" ] || die ".env 里没有 JELLYFIN_API_KEY（Jellyfin 后台 → 控制台 → API 密钥 → 新建）"
    curl -fsS -X POST -H "Authorization: MediaBrowser Token=\"$JELLYFIN_API_KEY\"" \
      http://127.0.0.1:8096/Library/Refresh && ok "Jellyfin 正在重新扫描"
    ;;
  *) die "用法: chi media [usage|clean [--dry-run]|scan]，下载用 chi fetch <url>" ;;
esac
