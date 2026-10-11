# CLI reference

Every operation goes through `bin/chi`. The logic lives in `scripts/`; `bin/chi` only dispatches. Run it from
anywhere (it finds its own repository), or add an alias:

```bash
echo 'alias chi=~/chi-server/bin/chi' >> ~/.zshrc
```

`chi help` (or no arguments) prints the summary. Unknown commands print the summary and exit 1.

Most commands require `.env` (run `chi init` first) and, for stack commands, a running Docker runtime.

## Setup

### `chi init`

Create `.env` from `.env.example`, or complete an existing one. Idempotent.

- Appends keys that exist in `.env.example` but not in `.env`.
- Fills empty or `CHANGE_ME` values: `DATA_DIR`, `MEDIA_DIR`, `RESTIC_PASSWORD_FILE`, `TZ`, and random
  `OPEN_WEBUI_SECRET_KEY`, `N8N_ENCRYPTION_KEY`, `CLASH_SECRET`, `NTFY_TOPIC`.
- Sets `TS_FQDN` from `tailscale status` when Tailscale is logged in.
- Generates the restic password file if missing.

```bash
chi init
```

### `chi bootstrap [step...]`

Provision the Mac. Steps: `dotfiles brew macos runtime tailscale ollama`. No arguments runs all, in order.

```bash
chi bootstrap                # everything
chi bootstrap macos          # re-apply server settings only
chi bootstrap runtime        # after switching CHI_RUNTIME
chi bootstrap tailscale ollama
```

See [Getting started](getting-started.md#4-bootstrap) for what each step does.

### `chi unattended`

Make the server survive reboots without anyone present. Needs an interactive terminal because it asks for
passwords; run it over `ssh -t`:

```bash
ssh -t chi-mini 'cd ~/chi-server && bin/chi unattended'
```

Steps: set your user as Tailscale operator and apply serve rules; turn FileVault off; enable auto-login
(verified, not assumed); require a password immediately after screensaver or display sleep and install a
LaunchAgent that locks the screen 3 seconds after login. Re-run it if FileVault was still decrypting. Details:
[Operations](operations.md#unattended-mode).

### `chi doctor`

Read-only health check on the server. Exits with the number of failed checks.

```bash
chi doctor
```

### `chi remote-check [host]`

End-to-end check from a client machine, as a user would see it. Default host: `chi-mini` (an SSH host alias).
Needs no `.env` on the client; it reads `TS_FQDN`, `PUBLIC_DOMAIN` and `CHI_STACKS` from the server.

```bash
chi remote-check
chi remote-check my-server
CHI_REMOTE_DIR=/opt/chi-server chi remote-check
```

Checks: `tailscale ping` (warns when relayed through DERP), passwordless SSH, the public domain, each tailnet
service, the onboarding page, LAN Jellyfin, and `chi doctor` on the server. See
[Remote access](remote-access.md#end-to-end-check).

## Stacks

A stack is a directory under `stacks/`. With no stack arguments, these commands act on `CHI_STACKS`.

| Command | Action |
|---|---|
| `chi stacks` | List stacks with their description; `*` marks enabled ones. |
| `chi up [stack...]` | Run each stack's `pre-up.sh`, then `docker compose up -d --remove-orphans`. |
| `chi down [stack...]` | `docker compose down`. Data in `DATA_DIR` is kept. |
| `chi restart [stack...]` | `docker compose restart`. |
| `chi ps [stack...]` | `docker compose ps`. |
| `chi logs <stack> [service]` | Follow the last 200 log lines (Ctrl-C to quit). |

```bash
chi stacks
chi up                       # all enabled stacks
chi up vault                 # one stack (it need not be in CHI_STACKS)
chi restart media
chi logs public cloudflared
chi down photos
```

### `chi update [--no-brew]`

Upgrade everything you run:

1. Unless `--no-brew`: `brew update && brew upgrade`; restart Ollama if running; re-allow mihomo in the
   firewall and restart it if running.
2. For each enabled stack: `docker compose pull` and `up -d`. For `photos`, it warns that Immich's compose file
   is not refreshed automatically.
3. `docker image prune -f`.

```bash
chi update
chi update --no-brew         # containers only
```

### `chi serve [apply|status|reset]`

Publish stacks over HTTPS on your tailnet with `tailscale serve`. Default: `apply`.

| Subcommand | Action |
|---|---|
| `apply` | For each enabled stack, publish every `SERVE` pair from `stack.conf`. Also publish `:8008` (onboarding page) if generated, and `:8007` (mihomo dashboard) while mihomo is running. |
| `status` | Show current serve rules. |
| `reset` | Remove all serve rules. |

```bash
chi serve
chi serve status
```

Requires `TS_FQDN`. Needs sudo unless you ran `chi unattended` (which makes your user the Tailscale operator).

## Media and sharing

### `chi fetch <url> [folder]`

Queue a download in MeTube at up to `MEDIA_MAX_HEIGHT`. Anything yt-dlp supports works. The optional folder is
relative to `Downloads/`.

```bash
chi fetch 'https://www.youtube.com/watch?v=VIDEO_ID'
chi fetch 'https://www.youtube.com/watch?v=VIDEO_ID' Lectures
```

### `chi media [usage|clean|scan|sub|iptv]`

Default: `usage`.

| Subcommand | Action |
|---|---|
| `usage` | Size of `Downloads/`, `Keep/`, `Movies/`, `TV/`, the cap, and free disk space. |
| `clean [--dry-run]` | If `Downloads/` exceeds `MEDIA_MAX_GB`, delete the oldest files until it fits. Other folders are never touched. |
| `scan` | Ask Jellyfin to rescan libraries now (needs `JELLYFIN_API_KEY`). |
| `sub` / `sub list` | List MeTube subscriptions with their IDs. |
| `sub add <url> [folder] [title-regex]` | Subscribe to a channel or playlist; checked every 6 hours. Existing videos are marked as seen; only new ones download. |
| `sub rm <id>` | Remove a subscription. |
| `sub check` | Check all subscriptions now. |
| `iptv` | Download the IPTV playlists, test-play every channel, keep the working ones, and register them in Jellyfin Live TV (needs `JELLYFIN_API_KEY`). |

```bash
chi media
chi media clean --dry-run
chi media sub add 'https://www.youtube.com/playlist?list=PLAYLIST_ID' MyShow
chi media sub add 'https://www.youtube.com/@channel/videos' News 'Evening News'
chi media sub rm 3
chi media iptv
```

### `chi onboard`

Render the onboarding page and PAC file into `$DATA_DIR/share`, publish them on `https://<TS_FQDN>:8008`, and
print an invite message plus the admin checklist. Re-run after changing ports, hostname or `MEDIA_MAX_GB`; the
URL stays the same. See [Guest access](guest-access.md).

## Network and devices

### `chi proxy [install|apply|test|status|logs|firewall|uninstall]`

Split-routing proxy (mihomo). Default: `status`.

| Subcommand | Action |
|---|---|
| `install` | Install mihomo, render the config, start it, allow it through the firewall, run `test`. |
| `apply` | Re-render the config after editing `.env` or `config/mihomo/config.yaml.tmpl`, validate, restart. |
| `test` | Compare the exit location a test site sees directly and through the proxy. |
| `status` | Service status and the currently selected upstream node. |
| `logs` | Follow the mihomo log. |
| `firewall` | Re-allow the mihomo binary in the application firewall (needed after Homebrew upgrades; `chi update` does it). |
| `uninstall` | Stop mihomo and remove the rendered config. |

```bash
chi proxy install
chi proxy apply
chi proxy test
```

See [Split routing](modules/split-routing.md).

### `chi tv [connect|install|proxy|vpn|apps|shell]`

Manage an Android TV / Google TV box over adb (installs `android-platform-tools` if needed). No subcommand prints
help, including how to enable USB debugging on the box. A bare IP gets port `:5555`.

| Subcommand | Action |
|---|---|
| `connect <ip>` | Connect to the box. Accept "Always allow" on the TV the first time. |
| `install <apk>` | Sideload an APK (push, then install on the box; tolerates Play Protect prompts). |
| `proxy <ip> on\|off` | Point the box's global HTTP proxy at the Mac's mihomo, or clear it. |
| `vpn <ip> <package>\|off` | Make a VPN app always-on (no lockdown) so it reconnects after reboot, or clear it. |
| `apps` | List third-party packages on the connected box. |
| `shell` | Open an adb shell. |

```bash
chi tv connect 192.168.1.50
chi tv install ./app.apk
chi tv proxy 192.168.1.50 on
chi tv vpn 192.168.1.50 com.example.vpn
```

See [Android TV](modules/android-tv.md).

## Data and schedules

### `chi backup [init|run|snapshots|check]`

restic backup of `DATA_DIR`. Default: `run`.

| Subcommand | Action |
|---|---|
| `init` | Create the repository (no-op if it exists). |
| `run` | Dump Immich's database, stop enabled stacks (except `photos`), back up app data, restart them, back up the Immich library and `.env`, then prune (7 daily, 4 weekly, 6 monthly). |
| `snapshots` | List snapshots. |
| `check` | Verify the repository, reading a random 5% of the data. |

```bash
chi backup init
chi backup run
chi backup snapshots
```

### `chi schedule [install|uninstall]`

Install or remove launchd jobs. Default: `install`. Re-run after changing `RESTIC_REPOSITORY`, `HC_PING_URL`,
`BACKUP_HOUR` or `CHI_STACKS`. Job table: [Architecture: scheduled jobs](architecture.md#scheduled-jobs).

```bash
chi schedule
chi schedule uninstall
```

## Helper scripts

These are run directly, not through `bin/chi`.

| Script | Purpose |
|---|---|
| `scripts/kuma-seed.sh [user]` | Add default monitors and an ntfy notification to Uptime Kuma. See [Operations](operations.md#alerts). |
| `scripts/friend-ts.sh invite\|allow\|revoke\|cleanup\|status` | Share the machine and manage per-guest port grants through the Tailscale API. See [Guest access](guest-access.md). |
| `scripts/friend-mac.sh add\|remove\|status` | Create guest macOS accounts for screen sharing. See [Guest access](guest-access.md). |
| `stacks/photos/fetch.sh [--force]` | Download (or refresh) Immich's upstream compose file. See [photos](modules/photos.md). |
