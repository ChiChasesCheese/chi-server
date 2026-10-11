# Getting started

This guide takes you from a new Mac mini to running services you can reach from your laptop and phone. Plan
for about an hour, most of it waiting for downloads.

Everything that can be automated is in `chi bootstrap`. This page also covers the few things you must click by
hand, and the one decision you must make yourself (FileVault, see [Operations](operations.md#unattended-mode)).

## Prerequisites

| Item | Notes |
|---|---|
| Mac mini, Apple Silicon | 16 GB RAM is enough for `core`, `automation`, `vault`, `media` and small models. See the memory guide in [ai](modules/ai.md#memory-planning). |
| macOS 26 (Tahoe) or newer | Update first: System Settings -> General -> Software Update. |
| A Tailscale account | Free plan is fine. The Mac and every client device join the same tailnet. |
| A client machine | Your laptop, used for `chi remote-check` and day-to-day management. |
| Optional: external disk | For Time Machine, restic backups, or a large media library. |
| Optional: Cloudflare account and a domain | Only for the [public](modules/public.md) stack. |

## 1. Physical setup

- **Use Ethernet.** Wi-Fi works, but a server should be wired.
- **Reserve an IP** for the Mac in your router (DHCP reservation). Tailscale does not need it, but LAN clients
  (TV boxes, the proxy) do. Some ISP gateways ignore reservations; see
  [Operations: troubleshooting](operations.md#troubleshooting).
- **Optional: a UPS.** Power blips are the most common "outage" of a home server.
- **Optional: an HDMI dummy plug.** Without a display, screen sharing may pick an odd resolution.

## 2. Manual macOS settings

Create your admin account. Use **one dedicated account** for the server; every service runs under it. Give it a
password you use nowhere else (auto-login stores it in a reversible form, see [Security](security.md)).

Avoid signing in with your primary Apple ID with iCloud Photos or Documents sync enabled: it would pull your
whole iCloud library onto the server.

Then, in System Settings:

- [ ] **Privacy & Security -> Full Disk Access**: add Terminal (or the terminal app you use). Without it,
  `systemsetup` (Remote Login, restart after freeze) fails. The script tells you if it does.
- [ ] **General -> Sharing -> Remote Login**: on, "Allow access for: Only these users" -> just you.
- [ ] **General -> Sharing -> Screen Sharing**: on, also limited to you. You will need it when a reboot stops at
  a graphical prompt.
- [ ] **Notifications**: turn off what you do not need.

## 3. Clone and configure

```bash
git clone https://github.com/ChiChasesCheese/chi-server.git ~/chi-server
cd ~/chi-server
bin/chi init
open -e .env
```

`chi init` copies `.env.example` to `.env` (mode 600), fills `DATA_DIR`, `MEDIA_DIR`, `TZ` and random secrets,
and generates a restic password file. **Save the restic password in your password manager now.**

Review at least these keys (full list in [Configuration](configuration.md)):

| Key | Set it to |
|---|---|
| `CHI_HOSTNAME` | The machine name on your LAN and tailnet (default `chi-mini`). |
| `CHI_STACKS` | The stacks to run, e.g. `"core ai vault"`. Run `bin/chi stacks` to see them all. |
| `CHI_RUNTIME` | `orbstack` (default) or `colima`. |
| `BIND_ADDR` | Keep `127.0.0.1` unless LAN devices without Tailscale need direct access. |

## 4. Bootstrap

```bash
bin/chi bootstrap
```

It runs these steps in order; each is idempotent and can run alone (`bin/chi bootstrap macos`):

| Step | What it does |
|---|---|
| `dotfiles` | Optional. Applies your chezmoi dotfiles if `DOTFILES_REPO` is set; skipped otherwise. |
| `brew` | Installs Xcode Command Line Tools (re-run afterwards if prompted), Homebrew and the `Brewfile`. |
| `macos` | Server settings: never sleep, restart after power loss, Wake on LAN, firewall with stealth mode, SSH, hostname, security-only automatic updates. Asks for sudo. |
| `runtime` | Installs and starts OrbStack (enables start at login) or Colima. Accept OrbStack's terms on first launch. |
| `tailscale` | Installs the open-source `tailscaled` as a system daemon and logs it in. Open the printed link. |
| `ollama` | Installs Ollama as a login service, only if `ai` is in `CHI_STACKS`. |

## 5. Tailscale admin console

In the [Tailscale admin console](https://login.tailscale.com/admin):

1. **Machines** -> your Mac mini -> **Disable key expiry**. Otherwise the node drops off the tailnet after 180
   days, most likely when you are away.
2. **DNS** -> enable **MagicDNS** and **HTTPS Certificates**. `chi serve` needs both.

Then fill in the tailnet name:

```bash
bin/chi init          # sets TS_FQDN, e.g. chi-mini.your-tailnet.ts.net
```

## 6. Start the stacks

```bash
bin/chi up
```

`chi up` runs each stack's `pre-up.sh` hook (if any), then `docker compose up -d`. The first run pulls images
and can take a while. Check status with `bin/chi ps`, follow logs with `bin/chi logs <stack>`.

## 7. Publish over HTTPS

```bash
bin/chi serve
```

This maps each stack's ports (from its `stack.conf`) to HTTPS ports on your tailnet name and prints the URLs:

| URL | Service |
|---|---|
| `https://<TS_FQDN>` | Homepage |
| `https://<TS_FQDN>:8001` | Uptime Kuma |
| `https://<TS_FQDN>:8002` | Dozzle |
| `https://<TS_FQDN>:8003` | Open WebUI |
| `https://<TS_FQDN>:8004` | n8n |
| `https://<TS_FQDN>:8005` | Vaultwarden |
| `https://<TS_FQDN>:8006` | Immich |
| `https://<TS_FQDN>:8009` / `:8010` | Jellyfin / MeTube |

Only enabled stacks are published. Each module page describes first-run setup.

## 8. Health check

```bash
bin/chi doctor
```

`chi doctor` is read-only. It checks power settings, firewall, SSH, FileVault and auto-login state, disk use,
update policy, Tailscale, `.env`, every enabled stack (running and healthy), stale hostnames inside containers,
Ollama, media disk quota, the Cloudflare tunnel and the split-routing proxy. It exits with the number of
problems found.

## 9. Check from your laptop

On your client machine, install Tailscale and log in to the same tailnet, then set up SSH. Create a dedicated
key and add an entry to `~/.ssh/config` (replace the placeholders):

```sshconfig
Host chi-mini
  HostName chi-mini
  User <server-username>
  IdentityFile ~/.ssh/chi_mini_ed25519
  IdentitiesOnly yes
  ServerAliveInterval 30
```

```bash
ssh-keygen -t ed25519 -f ~/.ssh/chi_mini_ed25519
ssh-copy-id -i ~/.ssh/chi_mini_ed25519.pub chi-mini
```

`<server-username>` is the account on the Mac mini, which may differ from your laptop username. MagicDNS makes
the short name `chi-mini` resolve on the tailnet.

Clone the repository on the laptop as well and run the end-to-end check:

```bash
git clone https://github.com/ChiChasesCheese/chi-server.git ~/chi-server
~/chi-server/bin/chi remote-check chi-mini
```

It verifies Tailscale connectivity (and warns if traffic is relayed), passwordless SSH, every published
service, the public domain if configured, LAN Jellyfin, and runs `chi doctor` on the server.

## Next steps

- Make the server survive reboots: [Operations: unattended mode](operations.md#unattended-mode).
- Set up backups and alerts: [Operations](operations.md#backups).
- Install scheduled jobs: `bin/chi schedule`.
- Turn on Time Machine to an external disk as well. It covers the whole system; restic covers service data
  off-site.
- Give others access: [Guest access](guest-access.md).
