# Remote access

By default, everything is reachable only on your tailnet, over HTTPS, with no open router ports.

```
phone / laptop --(Tailscale, WireGuard)--> https://<host>.<your-tailnet>.ts.net[:port]
```

## Tailnet access

- Install Tailscale on each device and log in to the same tailnet.
- Services live at `https://<TS_FQDN>` (Homepage) and `https://<TS_FQDN>:<port>` (see the table in
  [Getting started](getting-started.md#7-publish-over-https)). `chi serve status` lists the current rules.
- SSH: `ssh <server-username>@chi-mini` (MagicDNS resolves the short name).
- Screen sharing: `open vnc://chi-mini`.
- Household members can be invited into your tailnet; friends are better served by sharing just this machine
  ([Guest access](guest-access.md)).

### Access control

By default every device in a tailnet can reach every other device. If you invite others, restrict them in the
admin console under **Access Controls**. Example: admins get everything, a `family` group gets only Homepage and
Immich on a tagged server:

```jsonc
{
  "grants": [
    { "src": ["autogroup:admin"], "dst": ["*"], "ip": ["*"] },
    { "src": ["group:family"], "dst": ["tag:server"], "ip": ["tcp:443", "tcp:8006"] }
  ]
}
```

Tag the machine `tag:server` first. Check the syntax against Tailscale's grants documentation; the console
validates on save.

## Client machine setup

Your laptop is the control machine: you edit the repo there, push, and deploy to the server.

1. **Tailscale.** Install it and log in. The Homebrew cask (`brew install --cask tailscale-app`) needs sudo;
   the App Store version works too.
2. **SSH key and config.** Use a dedicated key and a host alias:

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

   Without an interactive terminal, accept the host key with
   `ssh-keyscan -t ed25519 chi-mini >> ~/.ssh/known_hosts` (a fingerprint obtained over Tailscale is
   trustworthy).

3. **Repository.** Clone it on the laptop too. Make changes there, commit, push; pull on the server.

Once SSH keys work, you can disable password login on the server with `CHI_SSH_KEY_ONLY=1` in `.env` and
`chi bootstrap macos`.

### Day-to-day from the laptop

| Task | Command on the laptop |
|---|---|
| Shell on the server | `ssh chi-mini` |
| End-to-end check | `bin/chi remote-check` |
| Health check on the server | `ssh chi-mini 'cd ~/chi-server && bin/chi doctor'` |
| Deploy changes | `git push`, then `ssh chi-mini 'cd ~/chi-server && git pull && bin/chi up'` |
| Reboot | `ssh chi-mini 'sudo -n /sbin/shutdown -r now'` (after the [sudoers setup](operations.md#passwordless-reboot)) |
| Desktop | `open vnc://chi-mini` |
| Host load | `ssh chi-mini btop` |

## End-to-end check

`chi remote-check [host]` runs on the client and checks the server the way a user would:

1. `tailscale ping`: warns if the connection is relayed through DERP (works, but slower; see
   [Direct connections](#direct-connections)).
2. Passwordless SSH (`BatchMode`).
3. Locates the checkout on the server and reads `TS_FQDN`, `PUBLIC_DOMAIN`, `CHI_STACKS` from its `.env`.
4. The public domain, if the `public` stack is enabled (530 / 1033 means cloudflared is not connected).
5. Each tailnet service of the enabled stacks, plus the onboarding page.
6. Jellyfin on the LAN (a failure is expected when you are not on the same LAN).
7. `chi doctor` on the server.

The default host is `chi-mini`. By default it looks for the checkout at `~/chi-server` on the server and falls back
to a legacy `~/chi-service` checkout. Set `CHI_REMOTE_DIR` to use another path:

```bash
CHI_REMOTE_DIR=/opt/chi-server bin/chi remote-check my-server
```

## Direct connections

Tailscale tries to connect peers directly and falls back to DERP relays. Relayed connections work but are slower.
If `chi remote-check` reports DERP:

- Forward **UDP 41641** on your router to the Mac mini's LAN IP. This is the only port forward worth considering,
  and it only helps WireGuard establish a direct path; it exposes no service.
- Check that the router does not block UDP or use symmetric NAT (`tailscale netcheck` shows details).

Never forward 22, 5900 or any admin port.

## Prettier names

Tailnet URLs look like `https://chi-mini.your-tailnet.ts.net:8006`. Options for nicer names:

**Rename the tailnet.** The admin console lets you pick a tailnet DNS name from generated options, which makes
the suffix friendlier. URLs still carry ports.

**Reverse proxy with your own domain, still private.**

- Create DNS records `*.home.example.com` -> the Mac's Tailscale IP (`100.x.y.z`). A public record pointing at
  a CGNAT address is harmless: outsiders cannot reach it.
- Run Caddy with a Cloudflare DNS-01 plugin to get a wildcard certificate, and proxy each subdomain to a
  `127.0.0.1` port.
- This adds a component to maintain, which is why it is not in the default setup.

**Cloudflare Tunnel, truly public.** Only for services that must be public, with Cloudflare Access in front.
See the [public module](modules/public.md).

## Tailscale Funnel

`tailscale funnel` publishes a tailnet service to the internet without a domain. It is handy for a temporary
webhook or demo, but limited to ports 443, 8443 and 10000, and adds no authentication layer. Use it only for
services that authenticate on their own. For anything long-lived, prefer the [public module](modules/public.md).
