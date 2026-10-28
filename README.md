# chi-server

chi-server turns an Apple Silicon Mac mini into an always-on home server. A single CLI, `bin/chi`, provisions
macOS, starts containerised services in self-contained "stacks", publishes them over HTTPS on your private
Tailscale network, backs up their data, and checks that everything still works after a reboot.

Everything that defines the server lives in this repository. Data lives in one directory (`DATA_DIR`) and
secrets live in one file (`.env`). If the machine dies, you clone the repo on a new Mac, restore those two
things from backup, and run the same commands again.

## Who it is for

- You own (or plan to buy) an Apple Silicon Mac mini running **macOS 26 or newer** and want it to run 24/7.
- You want local AI (Ollama on the Metal GPU), a password manager, a media library, automation, or a photo
  library without exposing ports on your router.
- You are comfortable with a terminal, SSH, and editing a `.env` file.

If you only need Linux containers and do not care about local LLMs, a small x86 box running Linux is a more
conventional choice. The Mac mini earns its place with unified memory for local models, very low idle power,
and silence.

## Features

| Module | What you get | Docs |
|---|---|---|
| `core` | Homepage dashboard, Uptime Kuma monitoring, Dozzle container logs | [core](docs/modules/core.md) |
| `ai` | Open WebUI in front of a native Ollama that uses the Metal GPU | [ai](docs/modules/ai.md) |
| `automation` | n8n workflow automation, with access to local models | [automation](docs/modules/automation.md) |
| `vault` | Vaultwarden (Bitwarden-compatible password manager) | [vault](docs/modules/vault.md) |
| `photos` | Immich photo library, using the upstream compose file | [photos](docs/modules/photos.md) |
| `media` | Jellyfin media server, MeTube (yt-dlp) downloader, subscriptions, live TV | [media](docs/modules/media.md) |
| `public` | Cloudflare Tunnel for the few things that must be public, on an isolated network | [public](docs/modules/public.md) |
| `scrape` | Firecrawl: a scraping API that turns websites into LLM-ready Markdown / JSON | [scrape](docs/modules/scrape.md) |
| Split routing | mihomo proxy that routes only selected sites through an upstream proxy | [split-routing](docs/modules/split-routing.md) |
| Android TV | Manage an Android TV / Google TV box over adb: sideload, proxy, always-on VPN | [android-tv](docs/modules/android-tv.md) |

Platform features shared by all modules:

- **One-command provisioning**: Homebrew, server-grade macOS settings (no sleep, restart after power loss,
  firewall, SSH), container runtime (OrbStack or Colima), Tailscale as a system daemon, Ollama.
- **Private HTTPS** for every service through `tailscale serve`. No domain, no port forwarding, automatic
  certificates.
- **Unattended reboots**: `chi unattended` turns FileVault off, enables auto-login, and locks the screen right
  after login so services come back after a power cut.
- **Backups** with restic (local disk, Backblaze B2, S3/R2), consistent snapshots of SQLite-based apps.
- **Alerts**: ntfy push notifications from Uptime Kuma and an external healthchecks.io heartbeat.
- **Health checks** on the server (`chi doctor`) and end-to-end from a client machine (`chi remote-check`).
- **Guest access** for friends and family: an onboarding page, Tailscale node sharing with port-level grants,
  and separate macOS accounts for screen sharing.

## Architecture

```
            Your laptop / phone (Tailscale client, anywhere)
                              |
                              |  WireGuard, no open router ports
                              v
+---------------------------- Mac mini (macOS 26+) -------------------------------+
|  tailscaled (system daemon, online at boot)                                     |
|    `- tailscale serve: https://<host>.<tailnet>.ts.net[:port]  (auto TLS)       |
|         :443  Homepage      :8001 Uptime Kuma   :8002 Dozzle                    |
|         :8003 Open WebUI    :8004 n8n           :8005 Vaultwarden               |
|         :8006 Immich        :8009 Jellyfin      :8010 MeTube                    |
|         :8007 mihomo UI     :8008 onboarding    :8011 Firecrawl API             |
|                     |                                                           |
|                     v  127.0.0.1:<port>                                         |
|  OrbStack / Colima (Linux VM) -- docker compose projects chi-<stack>            |
|         data in $DATA_DIR (default ~/srv/data)                                  |
|                     |                                                           |
|                     `- host.docker.internal:11434 --> Ollama (native, Metal)    |
|                                                                                 |
|  public stack: cloudflared --(isolated network)--> public apps                  |
|                     ^ outbound only                                             |
|  launchd: restic backup, media cleanup, IPTV refresh, heartbeat                 |
+---------------------------------------------------------------------------------+
                      |
                      v
            Cloudflare edge (only for the public stack)
```

See [docs/architecture.md](docs/architecture.md) for the components, the boot sequence and the design decisions.

## Quick start

On the Mac mini, after the physical and manual macOS steps in [Getting started](docs/getting-started.md):

```bash
git clone https://github.com/ChiChasesCheese/chi-server.git ~/chi-server
cd ~/chi-server

bin/chi init          # create .env (timezone, random secrets); review it, set CHI_STACKS
bin/chi bootstrap     # Homebrew, macOS settings, OrbStack, Tailscale, Ollama (asks for sudo)
bin/chi init          # again, after Tailscale login: fills in TS_FQDN
bin/chi up            # start every stack listed in CHI_STACKS
bin/chi serve         # publish them over HTTPS on your tailnet
bin/chi doctor        # health check; fix anything it flags
```

Then open `https://<CHI_HOSTNAME>.<your-tailnet>.ts.net` from any device on your tailnet.

Optional next steps: `chi unattended` (survive reboots), `chi backup init` and `chi schedule` (backups and
jobs). Add an alias so you can type `chi` instead of `bin/chi`:

```bash
echo 'alias chi=~/chi-server/bin/chi' >> ~/.zshrc
```

## Commands

| Command | Purpose |
|---|---|
| `chi init` | Create or complete `.env` |
| `chi bootstrap [step...]` | Provision the Mac: `dotfiles brew macos runtime tailscale ollama` |
| `chi unattended` | FileVault off, auto-login, lock at login (run with `ssh -t`) |
| `chi doctor` | Read-only health check on the server |
| `chi remote-check [host]` | End-to-end check from a client machine |
| `chi stacks` | List stacks and which are enabled |
| `chi up / down / restart / ps [stack...]` | Manage stacks (default: all of `CHI_STACKS`) |
| `chi logs <stack> [service]` | Follow logs |
| `chi update [--no-brew]` | Upgrade Homebrew packages and container images |
| `chi serve [apply\|status\|reset]` | Publish stacks over HTTPS on your tailnet |
| `chi fetch <url> [folder]` | Queue a download in MeTube |
| `chi media [usage\|clean\|scan\|sub\|iptv]` | Media library management |
| `chi onboard` | Generate the onboarding page and an invite message |
| `chi proxy [install\|apply\|test\|status\|logs]` | Split-routing proxy (mihomo) |
| `chi tv [connect\|install\|proxy\|vpn\|apps\|shell]` | Manage an Android TV box over adb |
| `chi backup [init\|run\|snapshots\|check]` | restic backup of `DATA_DIR` |
| `chi schedule [install\|uninstall]` | Install or remove launchd jobs |

Full reference: [docs/cli.md](docs/cli.md).

## Repository layout

```
bin/chi                 the single entry point
scripts/                one script per command, plus lib.sh (shared helpers)
stacks/<name>/          compose.yaml, stack.conf, optional pre-up.sh / fetch.sh
config/                 templates: mihomo config, onboarding page, PAC file
launchd/                plist template for scheduled jobs
docs/                   documentation
Brewfile                host tools installed by `chi bootstrap brew`
.env.example            every setting, with comments
```

## Documentation

- [Getting started](docs/getting-started.md): from a new Mac mini to running services
- [Architecture](docs/architecture.md): components, networking, boot sequence, design decisions
- [Configuration](docs/configuration.md): every `.env` key
- [CLI reference](docs/cli.md)
- Modules: [core](docs/modules/core.md), [ai](docs/modules/ai.md), [automation](docs/modules/automation.md),
  [vault](docs/modules/vault.md), [photos](docs/modules/photos.md), [media](docs/modules/media.md),
  [public](docs/modules/public.md), [scrape](docs/modules/scrape.md), [split-routing](docs/modules/split-routing.md),
  [android-tv](docs/modules/android-tv.md)
- [Remote access](docs/remote-access.md): reaching and managing the server from other machines
- [Guest access](docs/guest-access.md): giving friends and family access
- [Operations](docs/operations.md): unattended mode, updates, alerts, backups, troubleshooting
- [Security](docs/security.md): threat model and hardening
- [Adding a stack](docs/adding-a-stack.md)
- [Roadmap](docs/roadmap.md)

## Contributing and license

See [CONTRIBUTING.md](CONTRIBUTING.md) and [SECURITY.md](SECURITY.md). Released under the [MIT License](LICENSE).
