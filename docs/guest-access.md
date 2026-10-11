# Guest access

This page covers giving friends and family access to the server: tailnet sharing with per-port limits, an
onboarding page, Jellyfin accounts, and separate macOS accounts for remote desktop use.

## Overview

| What the guest gets | How |
|---|---|
| Network access to this one machine | Tailscale **node sharing** (they use their own Tailscale account) |
| Only selected ports | Tailnet policy grants for `autogroup:shared` (and per-guest rules) |
| Setup instructions with your real addresses | Onboarding page from `chi onboard` at `https://<TS_FQDN>:8008` |
| Media | Their own Jellyfin user |
| A desktop on the Mac | Their own macOS account via Screen Sharing (`scripts/friend-mac.sh`) |

Why share the machine instead of inviting guests into your tailnet: sharing exposes only this node, the guest
keeps their own account, the rest of your devices stay invisible, and revoking is one click.

## The onboarding page

```bash
bin/chi onboard
```

This renders `config/onboarding/index.html.tmpl` and `chi.pac.tmpl` into `$DATA_DIR/share`, publishes them at
`https://<TS_FQDN>:8008` (tailnet only), and prints an admin checklist and a ready-to-send invite message.

The page explains how to install Tailscale on iPhone, Mac and Android, how to log in to Jellyfin, how to use the
PAC file for [split routing](modules/split-routing.md), an iOS share-sheet shortcut for downloads, and usage
rules. It contains no passwords or subscription URLs; the PAC file only contains the Mac's Tailscale IP.

Re-run `chi onboard` after changing ports, the hostname or `MEDIA_MAX_GB`. The URL does not change.

## One-time admin setup: limit guest ports

Restrict what shared users can reach. In the admin console -> **Access Controls**, keep full access for your own
devices and narrow `autogroup:shared`:

```jsonc
{
  "grants": [
    // Members of your tailnet (your own devices): everything
    { "src": ["autogroup:member"], "dst": ["*"], "ip": ["*"] },
    // Users this machine is shared with: only these ports
    //   443 Homepage, 8008 onboarding/PAC, 8009 Jellyfin, 7890 split-routing proxy
    //   add "tcp:8010" for MeTube or "tcp:8003" for Open WebUI
    { "src": ["autogroup:shared"], "dst": ["*"], "ip": ["tcp:443", "tcp:8008", "tcp:8009", "tcp:7890"] }
  ]
}
```

Shared users only see the machine you shared; this narrows the ports further. SSH, Uptime Kuma, Dozzle, the
mihomo dashboard and Vaultwarden become unreachable for them. Remove `tcp:7890` if guests should not use your
proxy (their proxied traffic uses your connection and your provider's quota).

### Scripted: `scripts/friend-ts.sh`

The `tailscale` CLI cannot edit the policy or create share invites, so this script uses the Tailscale API v2.
Create an API access token once (admin console -> Settings -> Keys -> **Generate access token**, at most 90
days) and store it:

```bash
(umask 077 && mkdir -p ~/.config/chi && pbpaste > ~/.config/chi/tailscale-api-key)
# Over SSH there is no clipboard: (umask 077 && cat > ~/.config/chi/tailscale-api-key), paste, Enter, Ctrl-D
```

| Command | Action |
|---|---|
| `scripts/friend-ts.sh invite [email]` | Create a single-use share invite link for this machine (with an email, Tailscale sends it; anyone with the link can accept). |
| `scripts/friend-ts.sh status` | Devices, invites (including `acceptedBy`), guest rules. |
| `scripts/friend-ts.sh allow <login> [port...]` | Allow a guest Screen Sharing (`tcp:5900`, `udp:5900-5902`) plus extra ports, e.g. `8010` or `tcp:8003`. |
| `scripts/friend-ts.sh revoke <login>` | Remove the guest's extra rule. The share itself is revoked in the console (Share... -> Revoke). |
| `scripts/friend-ts.sh cleanup` | Delete offline stale `<hostname>-*` nodes (e.g. left behind by an uninstalled app instance). |

`allow` and `revoke` back up the current policy to `~/.config/chi/acl-backups/`, validate the new policy via the
API (including a test that you can still reach the machine), show a diff and ask before writing with
`If-Match`. If the policy still contains an allow-all rule, `allow` offers to replace it with the tightened
policy above.

Notes:

- The API writes JSON, so `//` comments in your policy are lost. Restore from the backup if needed.
- `<login>` is the guest's **Tailscale login name** when they accepted (shown as `acceptedBy` in `status`, e.g.
  `name@github` for GitHub logins), not necessarily the email you invited.

## For each guest

1. Admin console -> Machines -> your Mac mini -> `...` -> **Share...** -> copy an invite link (one per person), or
   `scripts/friend-ts.sh invite`.
2. Jellyfin -> Dashboard -> Users -> create their account. You can limit libraries and disable deletion.
3. Send them the invite message printed by `chi onboard`, the link and their Jellyfin credentials.
4. To revoke: revoke the share in the console and disable the Jellyfin account.

## Device capabilities

| Device | Jellyfin | Other services | Split routing (PAC) |
|---|---|---|---|
| Mac / PC | Browser or app | Per policy | Anywhere, with Tailscale on and the system proxy set to the PAC URL |
| iPhone on Wi-Fi | Swiftfin / Jellyfin app | Per policy | Wi-Fi proxy set to the PAC URL; some apps may ignore it |
| iPhone on cellular | Yes | Per policy | No: iOS has no cellular proxy setting and allows one VPN at a time |
| TV box on your LAN | `http://<lan-ip>:8096` | - | `chi tv proxy` ([Android TV](modules/android-tv.md)) |

## Separate macOS accounts (remote desktop)

macOS Screen Sharing lets another user log in to **their own background session** while you use the Mac: they
see their desktop, you see yours.

### Admin setup

Run as your admin user, **without sudo** (the script asks for your password when needed and asks you to set the
guest's password):

```bash
scripts/friend-mac.sh add guest "Guest Name"    # add --ssh to also allow SSH
scripts/friend-mac.sh status                    # current state; no root needed
scripts/friend-mac.sh remove guest              # remove access; --delete also deletes the account and files
```

`add`:

- Creates a standard (non-admin) account, or sets a password on an existing one.
- Sets your home and theirs to mode 700.
- Restricts Screen Sharing (group `com.apple.access_screensharing`) and SSH (`com.apple.access_ssh`, admins only
  unless `--ssh`) to listed users.
- Turns off "VNC viewers may control screen with password" (a shared weak password that bypasses accounts).
- Tries to enable Screen Sharing with `launchctl`. This is unofficial (kickstart stopped working in macOS 12.1);
  if it fails, enable it by hand: System Settings -> General -> Sharing -> Screen Sharing -> (i) -> VNC password
  off, "Allow access for: Only these users".

On the tailnet, allow the guest `tcp:5900` (and `udp:5900-5902` for High Performance mode):
`scripts/friend-ts.sh allow <login>` does exactly that, without SSH.

### How the guest connects

1. On their Mac, with Tailscale connected, open the **Screen Sharing** app (or Finder -> Go -> Connect to Server)
   and enter `vnc://<TS_FQDN>`.
2. Enter their own username and password.
3. When told someone is using the Mac, choose **Log in as yourself** (not "Share screen", which asks to control
   your desktop).
4. When done, **log out** (Apple menu -> Log Out). Closing the window leaves the session running and using memory.

Use the built-in Screen Sharing app: separate sessions are an Apple extension to VNC. Most Windows VNC clients only
see the login window or the current screen; on iPad, clients that support "log in as yourself" may work. High
Performance mode needs Apple Silicon and macOS 14+ on both ends and a fast network; over Tailscale, Standard is
usually better.

In their session, a guest may sign in to their Apple Account but must **not enable Find My Mac**: that would put
the Mac under their Activation Lock.

### Screen sharing vs remote-control tools (ToDesk and similar)

Remote-control tools such as ToDesk attach to the **main console session**, not a separate one. After
auto-login, the console session is the server account. The rule:

- **When you leave, lock the screen with Ctrl+Cmd+Q. Never log out.** Logging out quits OrbStack, every
  container and Ollama.
- A guest connecting through such a tool sees the lock screen and uses **Switch User** to log in to their own
  account. Your session keeps running in the background, with all services.
- Prefer Screen Sharing ("Log in as yourself"): it gives each person an isolated session. Do not give guests
  the tool's permanent password and do not store the macOS password in it.

### Privacy and isolation

- With homes at 700, guests cannot read your files and you cannot read theirs, but an admin with sudo can read
  everything. Tell guests.
- Local users can reach every port bound to `127.0.0.1` and the Mac's Tailscale IP (Dozzle, Ollama, Uptime
  Kuma, admin pages). Tailnet policies only filter network traffic, not local access. Keep logins on services
  that have them; assume guests can use those that do not (Ollama, Dozzle). The OrbStack Docker socket lives in
  your home, so 700 protects it.
- `/Users/Shared` is readable and writable by every local user. Keep private files out of it.
- Each extra session costs roughly 2-4 GB of memory (more with a browser). On a 16 GB Mac, models slow down
  first. `scripts/friend-mac.sh status` shows sessions and free memory.

See also [Security](security.md#guest-isolation).
