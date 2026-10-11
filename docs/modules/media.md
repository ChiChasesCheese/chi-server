# media: Jellyfin and MeTube

The `media` stack turns the Mac into a small media server: download with MeTube (a web UI and API for yt-dlp),
watch with Jellyfin on TVs, phones and laptops.

| Service | Container | Local port | URL |
|---|---|---|---|
| Jellyfin | `chi-jellyfin` | 8096 (bound to `MEDIA_BIND_ADDR`, LAN by default) | `https://<TS_FQDN>:8009`, LAN `http://<lan-ip>:8096` |
| MeTube | `chi-metube` | 8081 | `https://<TS_FQDN>:8010` |

Approximate memory: 500 MB.

```
 chi fetch / MeTube web UI / iOS Shortcut / any HTTP client
                 |  URL
                 v
         MeTube (yt-dlp) --(optional: via mihomo)--> source sites
                 |
                 v
   $MEDIA_DIR/Downloads/<channel>/<date> <title> [id].<ext>
                 |
                 v
            Jellyfin --> TV box (LAN, http://<lan-ip>:8096)
                     --> phone / laptop (tailnet, https://<TS_FQDN>:8009)
```

## Library layout

`MEDIA_DIR` (default `$DATA_DIR/media`) is created by `chi up media`:

| Folder | Purpose | Auto-cleaned |
|---|---|---|
| `Downloads/` | MeTube output. Treated as a cache capped at `MEDIA_MAX_GB`. | Yes, oldest first |
| `Keep/` | Move anything you want to keep here. | Never |
| `Movies/`, `TV/` | Your own files. | Never |

Jellyfin mounts `MEDIA_DIR` read-only, so it cannot delete files. Media files are not backed up (they can be
downloaded again); Jellyfin's configuration and watch history in `$DATA_DIR/jellyfin` are.

### Disk planning

On a 256 GB Mac, budget roughly: macOS and system data 35-50 GB, container VM and images 10-15 GB, one 8B model
~5 GB, at least 30 GB free for updates and swap. That leaves about 60-100 GB for media. At 0.5-2 GB per hour of
1080p, `MEDIA_MAX_GB=60` holds 40-80 hours.

For a real library, use an external SSD formatted APFS, set `MEDIA_DIR=/Volumes/<disk>/media`, raise
`MEDIA_MAX_GB`, and run `chi up media`.

## Enable

```bash
# .env: add media to CHI_STACKS (it is in the default)
chi up media
chi serve
chi schedule        # daily cleanup and IPTV refresh
```

## Configure Jellyfin

Open `https://<TS_FQDN>:8009`:

1. Create the admin account.
2. Add libraries:
   - "Home videos and photos" -> `/media/Downloads` and `/media/Keep` for downloads.
   - "Movies" -> `/media/Movies`; "Shows" -> `/media/TV` for your own files.
3. Transcoding: keep the defaults. The container transcodes on the CPU; Apple Silicon handles 1080p in real
   time, and most TV boxes play the files directly.
4. Create a user per person (Dashboard -> Users).
5. Optional: Dashboard -> API Keys -> new key, put it in `JELLYFIN_API_KEY`. This enables `chi media scan`,
   `chi media iptv` and the Homepage widget.

Jellyfin scans for new files every 12 hours by default; `chi media scan` triggers it immediately.

## Downloading

| Method | How |
|---|---|
| CLI | `chi fetch '<url>' [folder]` |
| Web | `https://<TS_FQDN>:8010`, paste a link. Playlists and channels work. |
| iOS share sheet | A Shortcut that posts the URL; instructions are on the onboarding page (`chi onboard`). |
| Any HTTP client | `POST http://127.0.0.1:8081/add` with JSON `{"url": "...", "quality": "1080"}` (from the host). |
| Subscriptions | `chi media sub add <channel-or-playlist> [folder] [title-regex]` |

MeTube settings set by the stack:

- Output names that Jellyfin handles well: `<uploader>/<date> <title> [id].<ext>`.
- `pre-up.sh` prefers H.264 + AAC (`format_sort`): many TV boxes cannot hardware-decode AV1/VP9 and the
  container cannot hardware-transcode.
- If the split-routing proxy is listening on `CLASH_PORT` when you run `chi up media`, MeTube downloads through
  it. Otherwise it downloads directly. Re-run `chi up media` after installing the proxy.
- yt-dlp updates itself to nightly every day at 03:30. When downloads suddenly fail, wait for the update or
  `chi restart media`.

### Subscriptions

Subscribe to a playlist rather than a whole channel, or add a title regex; otherwise trailers and extras fill
the cap quickly.

```bash
chi media sub add 'https://www.youtube.com/playlist?list=PLAYLIST_ID' MyShow
chi media sub add 'https://www.youtube.com/@channel/videos' News 'Evening News'
chi media sub            # list, with IDs
chi media sub rm <id>
chi media sub check      # check now instead of waiting 6 hours
```

Existing videos are marked as seen when you subscribe; only new uploads download. Fetch older episodes with
`chi fetch`.

## Live TV (IPTV)

`chi media iptv` downloads public M3U playlists (`IPTV_M3U_URLS`, default: iptv-org's China playlist), test-plays
every channel from this Mac, writes the working ones to `$DATA_DIR/jellyfin/config/livetv/cn.m3u`, registers it
as a Live TV tuner in Jellyfin once, and refreshes the guide. `chi schedule` re-runs it daily at 05:27 because
public streams change addresses often.

- There is no EPG; you see what is on now.
- Some streams are geo-restricted and fail from outside their region.
- iptv-org only collects links; streams come from the broadcasters' CDNs.

## TV boxes

- Install the official Jellyfin app on the box and use `http://<mac-lan-ip>:8096`. The box does not need
  Tailscale.
- Give the Mac (and the box) fixed LAN addresses ([Operations](../operations.md#troubleshooting) covers DHCP
  reservation quirks).
- Some boxes have 100 Mbit Ethernet; Wi-Fi 6 can be faster for high-bitrate 4K.
- To manage the box remotely (sideload apps, set a proxy), see [Android TV](android-tv.md).

## Operate

```bash
chi media                  # usage
chi media clean --dry-run  # preview what the nightly cleanup would delete
chi logs media metube
```

Scheduled jobs (via `chi schedule`, only when `media` is enabled): `media-clean` daily 05:47, `media-iptv` daily
05:27.

## Troubleshoot

| Symptom | Check |
|---|---|
| `chi fetch` says MeTube is not responding | `chi ps media`; `chi up media`. |
| All downloads fail | yt-dlp is outdated: wait for the nightly update or `chi restart media`. |
| Geo-restricted downloads fail | Install the [split-routing proxy](split-routing.md), then `chi up media`. Some sites also need a cookies file uploaded in MeTube. |
| New downloads not in Jellyfin | `chi media scan` (needs `JELLYFIN_API_KEY`). |
| TV box cannot reach Jellyfin | `MEDIA_BIND_ADDR` must be `0.0.0.0`; check the Mac's LAN IP; same network. |
| Disk full | `chi media`; lower `MEDIA_MAX_GB`; `chi media clean`. |

## Why Jellyfin runs in a container

Native Jellyfin could use VideoToolbox hardware transcoding, but most clients play files directly, Apple
Silicon handles 1080p software transcoding, and the container is managed by `chi up/update/backup` like
everything else. If you regularly transcode 4K for several viewers, switch to the native app
(`brew install --cask jellyfin`) and move the config directory over.

## Legal note

Many sites' terms forbid downloading. Personal viewing is a grey area; redistribution is not. You are
responsible for what you download.
