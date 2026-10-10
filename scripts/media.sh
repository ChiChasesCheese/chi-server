#!/usr/bin/env bash
# 媒体库管理。
#   chi fetch <url> [文件夹]    交给 MeTube 下载（YouTube / B 站 / 上千个站点，yt-dlp 支持的都行）
#   chi media usage             看占用
#   chi media clean [--dry-run] Downloads/ 超过 MEDIA_MAX_GB 时，从最旧的文件开始删
#   chi media scan              让 Jellyfin 立刻重新扫描媒体库
#   chi media sub [list]        MeTube 订阅：频道 / 播放列表出新视频就自动下载
#   chi media sub add <url> [文件夹] [标题正则]   例：只要正片 '第\d+集|EP\d+'
#   chi media sub rm <id> | check
#   chi media iptv              刷新直播频道（央视/卫视公开源，只留能播的）并接入 Jellyfin「直播电视」
set -euo pipefail
. "$(dirname "$0")/lib.sh"
ensure_brew_path
load_env
MEDIA_DIR="${MEDIA_DIR:-$DATA_DIR/media}"
MAX_GB="${MEDIA_MAX_GB:-60}"
DL="$MEDIA_DIR/Downloads"

jf() {
  [ -n "${JELLYFIN_API_KEY:-}" ] || die ".env 里没有 JELLYFIN_API_KEY（Jellyfin 后台 → 控制台 → API 密钥 → 新建）"
  local path="$1"; shift
  curl -fsS -H "Authorization: MediaBrowser Token=\"$JELLYFIN_API_KEY\"" "$@" "http://127.0.0.1:8096$path"
}

metube() {
  local path="$1" out; shift
  out="$(curl -sS --fail-with-body -H 'Content-Type: application/json' "$@" "http://127.0.0.1:8081/$path")" \
    || die "MeTube 出错（chi up media 了吗？）：$out"
  printf '%s\n' "$out"
}

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
    jf /Library/Refresh -X POST && ok "Jellyfin 正在重新扫描"
    ;;
  sub)
    case "${1:-list}" in
      list)
        metube subscriptions | jq -r 'if length == 0 then "（还没有订阅）" else .[] |
          "\(.id)  \(if .enabled then "开" else "停" end)  每\(.check_interval_minutes)分钟  \(.folder // "")  \(.name // .url)\(if .title_regex then "  [只要: \(.title_regex)]" else "" end)" end'
        ;;
      add)
        url="${2:-}"; [ -n "$url" ] || die "用法: chi media sub add <频道或播放列表 url> [文件夹] [标题正则]"
        # 加订阅时 MeTube 把现有视频都标成“已看过”，只下载之后的新视频，不会一下塞满硬盘
        body="$(jq -nc --arg u "$url" --arg q "${MEDIA_MAX_HEIGHT:-1080}" --arg f "${3:-}" --arg r "${4:-}" \
          '{url: $u, download_type: "video", format: "any", quality: $q, folder: $f, check_interval_minutes: 360}
           + (if $r == "" then {} else {title_regex: $r} end)')"
        resp="$(metube subscribe -X POST -d "$body")"
        case "$resp" in *'"ok"'*) ok "已订阅：${url}（每 6 小时查一次新视频）" ;; *) die "MeTube 返回：$resp" ;; esac
        ;;
      rm)
        [ -n "${2:-}" ] || die "用法: chi media sub rm <id>（id 见 chi media sub）"
        metube subscriptions/delete -X POST -d "$(jq -nc --arg i "$2" '{ids: [$i]}')" >/dev/null && ok "已删除订阅 $2"
        ;;
      check) metube subscriptions/check -X POST -d '{}' >/dev/null && ok "已触发全部订阅立即检查" ;;
      *) die "用法: chi media sub [list|add <url> [文件夹] [标题正则]|rm <id>|check]" ;;
    esac
    ;;
  iptv)
    # 公开直播源（默认 iptv-org 整理的中国频道）。大约一半是死的或限大陆 IP，所以先逐个试播再给 Jellyfin。
    # 在 Jellyfin 容器里是 /config/livetv/cn.m3u；Jellyfin 每次刷新指南时重读它
    out_dir="$DATA_DIR/jellyfin/config/livetv"
    mkdir -p "$out_dir"
    tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
    for src in ${IPTV_M3U_URLS:-https://iptv-org.github.io/iptv/countries/cn.m3u}; do
      curl -fsSL --max-time 30 "$src" | grep -v '^#EXTM3U' >>"$tmp/all.m3u" || warn "下载失败：$src"
    done
    [ -s "$tmp/all.m3u" ] || die "一个直播源都没下载到"
    log "逐个试播频道（约 1 分钟）"
    n="$(python3 -I "$CHI_ROOT/scripts/iptv-check.py" "$tmp/all.m3u" "$tmp/cn.m3u")"
    case "$n" in 0/*) die "没有一个频道能播（网络问题？）—— 保留旧列表" ;; esac
    mv "$tmp/cn.m3u" "$out_dir/cn.m3u"
    ok "能播的频道：$n → $out_dir/cn.m3u"
    if ! jf /System/Configuration/livetv | jq -e '.TunerHosts[]? | select(.Url == "/config/livetv/cn.m3u")' >/dev/null; then
      jf /LiveTv/TunerHosts -X POST -H 'Content-Type: application/json' \
        -d '{"Type": "m3u", "Url": "/config/livetv/cn.m3u", "FriendlyName": "中国直播", "TunerCount": 0}' >/dev/null
      ok "已在 Jellyfin 添加直播源「中国直播」"
    fi
    task="$(jf /ScheduledTasks | jq -r '.[] | select(.Key == "RefreshGuide") | .Id')"
    [ -n "$task" ] && jf "/ScheduledTasks/Running/$task" -X POST && ok "Jellyfin 正在刷新频道列表（onn 上：Jellyfin → 直播电视）"
    ;;
  *) die "用法: chi media [usage|clean [--dry-run]|scan|sub|iptv]，下载用 chi fetch <url>" ;;
esac
