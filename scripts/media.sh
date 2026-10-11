#!/usr/bin/env bash
# Media library management.
#   chi fetch <url> [folder]    hand off to MeTube (YouTube, Bilibili, and anything else yt-dlp supports)
#   chi media usage             show disk usage
#   chi media clean [--dry-run] when Downloads/ exceeds MEDIA_MAX_GB, delete starting from the oldest files
#   chi media scan              have Jellyfin rescan the library now
#   chi media sub [list]        MeTube subscriptions: auto-download new videos from a channel / playlist
#   chi media sub add <url> [folder] [title regex]   e.g. episodes only: 'EP\d+|Episode \d+'
#   chi media sub rm <id> | check
#   chi media iptv              refresh live TV channels (public IPTV lists, playable ones only) and wire them into Jellyfin Live TV
set -euo pipefail
. "$(dirname "$0")/lib.sh"
ensure_brew_path
load_env
MEDIA_DIR="${MEDIA_DIR:-$DATA_DIR/media}"
MAX_GB="${MEDIA_MAX_GB:-60}"
DL="$MEDIA_DIR/Downloads"

jf() {
  [ -n "${JELLYFIN_API_KEY:-}" ] || die "JELLYFIN_API_KEY is not set in .env (Jellyfin -> Dashboard -> API Keys -> new)"
  local path="$1"; shift
  curl -fsS -H "Authorization: MediaBrowser Token=\"$JELLYFIN_API_KEY\"" "$@" "http://127.0.0.1:8096$path"
}

metube() {
  local path="$1" out; shift
  out="$(curl -sS --fail-with-body -H 'Content-Type: application/json' "$@" "http://127.0.0.1:8081/$path")" \
    || die "MeTube error (did you run chi up media?): $out"
  printf '%s\n' "$out"
}

kb_of() { du -sk "$1" 2>/dev/null | awk '{print $1}'; }

# List files under Downloads as "mtime path", oldest first. Skip MeTube's temp dirs and hidden files
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
    url="${1:-}"; [ -n "$url" ] || die "Usage: chi fetch <url> [folder]"
    folder="${2:-}"
    quality="${MEDIA_MAX_HEIGHT:-1080}"
    body="$(jq -nc --arg u "$url" --arg q "$quality" --arg f "$folder" \
      '{url: $u, quality: $q} + (if $f == "" then {} else {folder: $f} end)')"
    resp="$(curl -fsS -X POST -H 'Content-Type: application/json' -d "$body" http://127.0.0.1:8081/add)" \
      || die "MeTube not responding (did you run chi up media?)"
    case "$resp" in *'"ok"'*) ok "Queued for download (${quality}p): $url" ;; *) die "MeTube returned: $resp" ;; esac
    ;;
  usage)
    [ -d "$MEDIA_DIR" ] || die "$MEDIA_DIR does not exist (chi up media creates it)"
    for d in Downloads Keep Movies TV; do
      [ -d "$MEDIA_DIR/$d" ] && printf '  %-10s %s\n' "$d" "$(du -sh "$MEDIA_DIR/$d" 2>/dev/null | cut -f1)"
    done
    log "Downloads limit ${MAX_GB}G (MEDIA_MAX_GB); free on disk: $(df -h "$MEDIA_DIR" | awk 'NR==2 {print $4}')"
    ;;
  clean)
    dry=0; [ "${1:-}" = "--dry-run" ] && dry=1
    [ -d "$DL" ] || exit 0
    limit_kb=$((MAX_GB * 1024 * 1024))
    used_kb="$(kb_of "$DL")"
    if [ "$used_kb" -le "$limit_kb" ]; then
      ok "Downloads $((used_kb / 1024 / 1024))G <= limit ${MAX_GB}G, nothing to clean"; exit 0
    fi
    log "Downloads $((used_kb / 1024 / 1024))G > limit ${MAX_GB}G, deleting oldest first (Keep/ Movies/ TV/ untouched)"
    list_oldest_first | while read -r _mtime path; do
      [ "$used_kb" -le "$limit_kb" ] && break
      size_kb="$(kb_of "$path")"
      if [ "$dry" = 1 ]; then echo "  [dry-run] would delete $path"; else rm -f "$path"; echo "  deleted $path"; fi
      used_kb=$((used_kb - size_kb))
    done
    # Remove empty directories (per-channel folders)
    [ "$dry" = 1 ] || find "$DL" -mindepth 1 -type d -empty ! -path '*/.*' -delete 2>/dev/null || true
    ok "Clean done"
    ;;
  scan)
    # Jellyfin scans every 12 hours by default; run this to see new downloads right away
    jf /Library/Refresh -X POST && ok "Jellyfin is rescanning"
    ;;
  sub)
    case "${1:-list}" in
      list)
        metube subscriptions | jq -r 'if length == 0 then "(no subscriptions yet)" else .[] |
          "\(.id)  \(if .enabled then "on " else "off" end)  every \(.check_interval_minutes)min  \(.folder // "")  \(.name // .url)\(if .title_regex then "  [only: \(.title_regex)]" else "" end)" end'
        ;;
      add)
        url="${2:-}"; [ -n "$url" ] || die "Usage: chi media sub add <channel or playlist url> [folder] [title regex]"
        # On subscribe MeTube marks all existing videos as seen and only downloads new ones, so the disk doesn't fill at once
        body="$(jq -nc --arg u "$url" --arg q "${MEDIA_MAX_HEIGHT:-1080}" --arg f "${3:-}" --arg r "${4:-}" \
          '{url: $u, download_type: "video", format: "any", quality: $q, folder: $f, check_interval_minutes: 360}
           + (if $r == "" then {} else {title_regex: $r} end)')"
        resp="$(metube subscribe -X POST -d "$body")"
        case "$resp" in *'"ok"'*) ok "Subscribed: ${url} (checks for new videos every 6 hours)" ;; *) die "MeTube returned: $resp" ;; esac
        ;;
      rm)
        [ -n "${2:-}" ] || die "Usage: chi media sub rm <id> (ids: chi media sub)"
        metube subscriptions/delete -X POST -d "$(jq -nc --arg i "$2" '{ids: [$i]}')" >/dev/null && ok "Removed subscription $2"
        ;;
      check) metube subscriptions/check -X POST -d '{}' >/dev/null && ok "Triggered an immediate check of all subscriptions" ;;
      *) die "Usage: chi media sub [list|add <url> [folder] [title regex]|rm <id>|check]" ;;
    esac
    ;;
  iptv)
    # Public live TV lists (default: iptv-org's China channels). About half are dead or geo-blocked, so test-play each
    # one before handing the list to Jellyfin. Inside the Jellyfin container it's /config/livetv/cn.m3u; Jellyfin
    # rereads it on every guide refresh
    out_dir="$DATA_DIR/jellyfin/config/livetv"
    mkdir -p "$out_dir"
    tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
    for src in ${IPTV_M3U_URLS:-https://iptv-org.github.io/iptv/countries/cn.m3u}; do
      curl -fsSL --max-time 30 "$src" | grep -v '^#EXTM3U' >>"$tmp/all.m3u" || warn "Download failed: $src"
    done
    [ -s "$tmp/all.m3u" ] || die "Could not download any channel list"
    log "Test-playing each channel (about 1 minute)"
    n="$(python3 -I "$CHI_ROOT/scripts/iptv-check.py" "$tmp/all.m3u" "$tmp/cn.m3u")"
    case "$n" in 0/*) die "No channel is playable (network problem?) - keeping the old list" ;; esac
    mv "$tmp/cn.m3u" "$out_dir/cn.m3u"
    ok "Playable channels: $n -> $out_dir/cn.m3u"
    if ! jf /System/Configuration/livetv | jq -e '.TunerHosts[]? | select(.Url == "/config/livetv/cn.m3u")' >/dev/null; then
      jf /LiveTv/TunerHosts -X POST -H 'Content-Type: application/json' \
        -d '{"Type": "m3u", "Url": "/config/livetv/cn.m3u", "FriendlyName": "China Live TV", "TunerCount": 0}' >/dev/null
      ok "Added live TV source \"China Live TV\" to Jellyfin"
    fi
    task="$(jf /ScheduledTasks | jq -r '.[] | select(.Key == "RefreshGuide") | .Id')"
    [ -n "$task" ] && jf "/ScheduledTasks/Running/$task" -X POST && ok "Jellyfin is refreshing the channel list (on the TV: Jellyfin -> Live TV)"
    ;;
  *) die "Usage: chi media [usage|clean [--dry-run]|scan|sub|iptv]; to download use chi fetch <url>" ;;
esac
