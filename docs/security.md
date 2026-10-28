# Security

This page describes what chi-server exposes, to whom, and the trade-offs it makes. Read it before you put data
you care about on the machine.

## Threat model

In scope:

- **Internet attackers.** Mitigated by opening no router ports; private services are reachable only over
  Tailscale, and public ones only through Cloudflare on an isolated network.
- **Devices and people on your LAN.** Mitigated by binding container ports to `127.0.0.1` (except Jellyfin by
  default) and the macOS firewall in stealth mode.
- **Guests you share the machine with.** Mitigated by tailnet grants and separate, non-admin macOS accounts.
- **Compromise of a public app.** Mitigated by the internal `public` Docker network.

Out of scope or accepted:

- **Physical theft.** With the default unattended mode, FileVault is off; a stolen disk is readable.
- **Your Tailscale or Cloudflare account being compromised.** Protect both with strong 2FA.
- **Local users with sudo.** An admin can read everything on the machine.
- **High availability.** A home server has no SLA.

## What is exposed where

| Surface | Reachable from | Contents |
|---|---|---|
| `tailscale serve` HTTPS ports (443, 8001-8011) | Your tailnet; shared users limited by grants | All published stacks, onboarding page, mihomo dashboard |
| Jellyfin `:8096` | LAN (with `MEDIA_BIND_ADDR=0.0.0.0`) and tailnet | Jellyfin login |
| mihomo `:7890` | LAN and tailnet, limited by `lan-allowed-ips` | HTTP/SOCKS proxy |
| SSH `:22`, Screen Sharing `:5900` | LAN and tailnet, allowed users only | Remote login |
| Cloudflare Tunnel hostnames | Internet | Only apps you route, ideally behind Access |
| `127.0.0.1` ports | Local users and containers on normal Docker networks | Every service, including Ollama (no auth) |

The macOS application firewall is on in stealth mode (no replies to pings or port probes). It automatically
allows signed apps such as OrbStack and Tailscale, so it does not replace careful port binding.
`BIND_ADDR=0.0.0.0` widens every container port to the LAN; use it only
on a trusted network.

## FileVault and auto-login

`chi unattended` turns FileVault off and enables auto-login so the server recovers from power cuts on its own
([Operations](operations.md#unattended-mode)). Understand the cost:

- **Data at rest is unencrypted.** Anyone with the machine can read the disk: photos, documents, `.env` with all
  service secrets, n8n credentials (the encryption key is in `.env` next to them).
- **`/etc/kcpassword` is reversible.** macOS stores the auto-login password with a trivial, well-known
  obfuscation. With FileVault off, anyone with the disk recovers the password. **Use a password for the server
  account that you use nowhere else**, and do not sign in to your primary Apple Account or keep personal keys on
  the server.
- **The desktop is briefly unlocked at boot.** The lock-at-login agent locks it 3 seconds after login and
  `sysadminctl -screenLock immediate` requires the password after screensaver or display sleep.
- Vaultwarden data stays protected: it is encrypted client-side with your master password.

If that is not acceptable, keep FileVault on (mode B) and plan for manual unlocks.

## Secrets

| Secret | Where | Notes |
|---|---|---|
| Service keys, tunnel token, subscription URL, API keys | `.env` | Created mode 600 by `chi init`. In `.gitignore`. Never commit it, never paste it into issues. |
| restic password | `~/.config/chi/restic-password` (600) | Without it backups are unreadable. Store a copy in a password manager outside this server. |
| Tailscale API token | `~/.config/chi/tailscale-api-key` | Has your own admin rights; at most 90 days. `friend-ts.sh` warns if the mode is not 600 and passes it to curl via stdin, never on the command line. |
| Kuma password file | wherever `KUMA_PASSWORD_FILE` points | Create it with `umask 077`. |
| Generated stack env | `stacks/*/.env` | Ignored by git (Immich DB password lives here). |
| Rendered mihomo config | `$(brew --prefix)/etc/mihomo/config.yaml` | Mode 600; contains the subscription URL. |

If a secret leaks: rotate it at the source (delete and recreate the Cloudflare tunnel, regenerate the
subscription, revoke the API token). Do not rotate `N8N_ENCRYPTION_KEY` on a live system: n8n would lose its
stored credentials.

## Alert channel privacy

On the public `ntfy.sh` server, a topic has no password: anyone who knows the name can subscribe to your alerts
or post fake ones. `chi init` generates a random 20-character suffix. Keep it secret, or run your own ntfy server
with authentication (`NTFY_SERVER`).

## Certificate Transparency

Enabling Tailscale HTTPS certificates publishes the machine's full name (`<host>.<tailnet>.ts.net`) in public
Certificate Transparency logs. Only the name is revealed, not the services, and the host is not reachable from
the internet. Pick a hostname that reveals nothing you mind. The same applies to Cloudflare hostnames.

## Tailscale

- **Key expiry.** Disable it for the server only (it would otherwise drop off after 180 days, probably while you
  are away). Keep it enabled for laptops and phones.
- **Operator, not sudo.** `chi unattended` makes your user the Tailscale operator, so `chi serve` needs no sudo.
  Do not add `tailscale` to passwordless sudo: that would allow `tailscale funnel` to publish services.
- **Grants.** Restrict `autogroup:shared` and any invited groups to the ports they need
  ([Guest access](guest-access.md#one-time-admin-setup-limit-guest-ports)).
- **Funnel** publishes without authentication. Use it only for services with their own auth, and only
  temporarily.

## Sudoers scope

The optional passwordless-reboot rule (`/etc/sudoers.d/chi-ops`) is limited to `shutdown`, `reboot`,
`fdesetup authrestart` and `pmset`. The worst an attacker with your account can do with it is reboot or change
power settings. Always validate with `visudo -cf` and keep the file mode 440. Do not widen it.

## SSH

- Remote Login is limited to listed users (`com.apple.access_ssh`); `friend-mac.sh` adds guests only with
  `--ssh`.
- Use keys. `CHI_SSH_KEY_ONLY=1` disables password and keyboard-interactive login and root login via a drop-in
  at `/etc/ssh/sshd_config.d/000-chi.conf`; the script refuses if `~/.ssh/authorized_keys` is empty. With
  FileVault on, test pre-boot unlock first.

## Containers

- `docker.sock` is mounted read-only into Homepage, Uptime Kuma and Dozzle. Socket access is root-equivalent on
  the container VM. Never publish these three.
- Ollama, MeTube and Dozzle have no authentication. Keep them on `127.0.0.1` and the tailnet.
- On OrbStack, containers on normal networks can reach host ports bound to `127.0.0.1`. Public apps therefore
  run on an internal network ([public: isolation](modules/public.md#isolation)).
- Images are pulled from upstream registries with mostly floating tags. `chi update` is manual so you can read
  release notes first.

## Guest isolation

- Guests get standard (non-admin) macOS accounts; homes are mode 700.
- Screen Sharing and SSH are restricted to listed users; the shared VNC password is disabled.
- Tailnet grants filter network traffic only. A guest logged in on the Mac can reach every `127.0.0.1` port.
  Services without logins (Ollama, Dozzle) are effectively available to them.
- `/Users/Shared` is world-writable.
- Guests must not enable Find My Mac in their session (Activation Lock).
- With remote-control tools that take over the console session, lock the screen (Ctrl+Cmd+Q) instead of logging
  out, and let guests use Switch User.

Details: [Guest access](guest-access.md).

## Reporting vulnerabilities

See [SECURITY.md](../SECURITY.md).
