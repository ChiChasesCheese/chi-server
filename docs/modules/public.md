# public: Cloudflare Tunnel

The `public` stack publishes a **few selected** web pages or APIs to the internet, for people without Tailscale
or for third-party callbacks. Everything you and your household use stays on the tailnet
([Remote access](../remote-access.md)).

| Service | Container | Ports | Purpose |
|---|---|---|---|
| cloudflared | `chi-cloudflared` | none | Tunnel connector; dials out to Cloudflare. Starts only when `CF_TUNNEL_TOKEN` is set. |
| hello | `chi-public-hello` | none | Placeholder app (`traefik/whoami`) to verify the path end to end. Replace it with your app. |

`stack.conf` has an empty `SERVE`: nothing from this stack is published on the tailnet.

```
visitor --HTTPS--> Cloudflare edge (TLS terminates here; WAF, Access, rate limits)
                        ^
                        |  cloudflared dials out (port 7844, QUIC, falls back to HTTP/2)
                        |
 Mac mini -- chi-cloudflared --(network "public", internal)--> chi-public-hello / your app
```

- No router ports are opened and your home IP does not appear in DNS. ISP IP changes do not matter.
- Costs: Cloudflare sees decrypted traffic; the free plan caps request bodies at 100 MB; when your home
  connection or the Mac is down, the site is down.

## Tunnel or `tailscale funnel`?

| | Cloudflare Tunnel (this stack) | `tailscale funnel` |
|---|---|---|
| Domain | Your own domain (DNS on Cloudflare) | Only `<host>.<tailnet>.ts.net` |
| Ports | 443, one subdomain per app | 443, 8443 or 10000 only |
| TLS | Terminated at Cloudflare | Terminated on your machine |
| Auth / protection | Access, WAF, rate limits built in | None; the app must handle it |
| Good for | Long-lived small sites, APIs, webhooks | Quick demos and temporary callbacks |

For a temporary need, `tailscale funnel 3000` (then `tailscale funnel reset`) is enough; you do not need this
stack.

## Enable

1. Move your domain's DNS to Cloudflare (the free plan is enough).
2. In the Cloudflare dashboard: **Networking -> Tunnels -> Create a tunnel** (older UI: Zero Trust -> Networks
   -> Tunnels). Name it, choose Docker, and copy the token after `--token` in the displayed command.
3. Edit `.env`:

   ```bash
   bin/chi init                       # adds CF_TUNNEL_TOKEN / PUBLIC_DOMAIN if missing
   ```

   ```
   CF_TUNNEL_TOKEN=<token>
   PUBLIC_DOMAIN=hello.example.com
   CHI_STACKS="core ai media public"
   ```

4. Start it and watch the logs:

   ```bash
   bin/chi up public
   bin/chi logs public cloudflared    # look for "Registered tunnel connection" (usually 4)
   bin/chi ps public                  # cloudflared should be (healthy)
   ```

5. In the tunnel: **Routes -> Add route -> Published application** (older UI: Public Hostname). Subdomain
   `hello`, your domain, Service URL `http://hello:80`.
6. Open `https://hello.example.com`. The whoami output (hostname, IP, headers) means the whole path works.
7. Run `bin/chi up core` so Homepage picks up `PUBLIC_DOMAIN`.

To take the public entry offline: clear `CF_TUNNEL_TOKEN` and run `bin/chi up public` (`pre-up.sh` removes
`chi-cloudflared`), or `bin/chi down public`.

### How it works

- `stacks/public/pre-up.sh` writes `stacks/public/.env` before each `chi up public`: `COMPOSE_PROFILES=tunnel`
  when a token is set, empty otherwise. `cloudflared` is in the `tunnel` profile, so it does not restart forever
  without a token.
- Health check: the image is distroless (no shell or curl), so the check runs `cloudflared tunnel ready`, which
  queries `/ready` on the metrics server and succeeds once at least one connection is up. Metrics listen on
  `127.0.0.1:2000` inside the container only, out of reach of apps on the same network.
- `restart: unless-stopped` reconnects after a Mac or runtime restart.

## Adding a public app

1. Add a service to `stacks/public/compose.yaml`: `container_name: chi-public-<name>`, `networks: [public]`,
   **no `ports`**, data in `${DATA_DIR}/public-<name>`.
2. Only if it must reach the internet (third-party APIs), also attach the `egress` network. That also lets it
   reach host ports bound to `127.0.0.1` (see Isolation below).
3. `bin/chi up public`.
4. Add a route: Service URL `http://<service-name>:<container-port>`. **Never use `localhost`,
   `host.docker.internal` or the host IP**: cloudflared is on the egress network, so that would publish Dozzle,
   Kuma or anything else on the host.
5. Put admin paths behind Cloudflare Access (below).
6. Add an Uptime Kuma HTTP monitor for the public URL. It goes out and back in, so it also catches a dropped
   tunnel.

### Exposing a service from another stack

For an existing service elsewhere (for example only n8n's webhooks), attach it to the external network
`chi-public_public` in its own compose file (run `chi up public` first so the network exists):

```yaml
services:
  n8n:
    networks: [default, public]
networks:
  public:
    external: true
    name: chi-public_public
```

Then use `http://chi-n8n:5678` as the Service URL. The service is still on its own stack's network and can reach
the host, so put it behind Access and allow only the callback path.

## Cloudflare Access

**Zero Trust -> Access controls -> Applications -> Create new application -> Self-hosted**:

- Public hostname: the subdomain, optionally with a path (`app.example.com/admin`).
- Policy: Action Allow, Include Emails = your address. Access denies by default; unmatched requests never reach
  your home.
- Login method: One-time PIN by email is enough.
- Paths that third parties call directly (such as `/webhook/`): create a more specific application with a
  **Bypass** policy.

Your Cloudflare account controls tunnel routing. Turn on 2FA.

## Protection basics (free plan)

- **WAF**: the Free Managed Ruleset is on by default; add a few custom rules (allowed countries, block scanner
  paths like `/wp-admin`).
- **Rate limiting**: one rule on the free plan; protect login or write endpoints.
- **Bot Fight Mode**, Security Level, and **Under Attack mode** during an attack.
- Apps see cloudflared's IP; the visitor's IP is in the `CF-Connecting-IP` header.

## Capacity

Your upload bandwidth is shared by public visitors, remote streaming over Tailscale and off-site backups. Small
APIs are limited by the app, not bandwidth. Let Cloudflare cache static assets. **Do not serve video or large
files** through the tunnel: Cloudflare's terms require their paid products for that, uploads cap at 100 MB, and a
few concurrent 1080p streams saturate a typical residential uplink. Keep Jellyfin and Immich on the tailnet.

Check your ISP's acceptable use policy: many residential plans prohibit running servers, usually with an
exception for personal, non-commercial use. Do not run commercial or high-traffic sites from home.

## Never publish

- Dozzle (logs often contain secrets), Uptime Kuma, Homepage: they mount `docker.sock`, which is root on the VM.
- Open WebUI admin, Ollama (no authentication).
- mihomo dashboard (9090) and proxy port (7890): you would run an open proxy.
- MeTube: no authentication; anyone could make your machine download.
- Vaultwarden, the n8n editor: only behind Access, if at all.
- SSH, VNC, screen sharing.

## Isolation

On OrbStack, containers on a normal Docker network can reach host ports bound to `127.0.0.1` through
`host.docker.internal`. Binding to `127.0.0.1` protects against the LAN, not against containers on the same Mac.
Therefore:

- Public apps sit on the `public` network with `internal: true`: no gateway, no `host.docker.internal`, no
  internet. A compromised app cannot reach the admin UIs on the host.
- Only cloudflared (and apps you explicitly attach to `egress`) can reach the internet, and thus the host.
- Admin services still bind to `127.0.0.1` and keep their own logins.

Self-test with a throwaway busybox container on the same network:

```bash
docker run --rm --network chi-public_public busybox:stable sh -c '
  wget -qO- -T3 http://hello:80 >/dev/null && echo "hello reachable (expected)"
  wget -qO- -T3 http://host.docker.internal:3001 >/dev/null 2>&1 && echo "host Kuma reachable (BAD)" || echo "host unreachable (expected)"
  wget -qO- -T3 http://1.1.1.1 >/dev/null 2>&1 && echo "internet reachable" || echo "no internet (expected)"'
```

For an app on `egress`, `docker exec chi-public-<name> wget -qO- -T3 http://host.docker.internal:3001` succeeding
is expected. Remember that risk.

## Troubleshoot

| Symptom | Check |
|---|---|
| Visitors see Cloudflare error 1033 / HTTP 530 | cloudflared is not connected. Most often the Mac rebooted and nobody is logged in, so the runtime did not start: check auto-login (`chi doctor`). Otherwise `chi logs public cloudflared` (bad token, outbound blocked). |
| 502 | The tunnel is up but the app is down or the Service URL is wrong. |
| `chi doctor` says the tunnel is not connected | It reads the last register/unregister/error line in the cloudflared logs. |
| Homepage public card has a broken link | `PUBLIC_DOMAIN` is empty; that is harmless. |

There is no SLA at home: power cuts, ISP outages and OS reboots take the site down. Host anything that needs
high availability elsewhere.

## References

- Remotely managed tunnels: <https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/get-started/create-remote-tunnel/>
- Run parameters: <https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/configure-tunnels/run-parameters/>
- Self-hosted apps with Access: <https://developers.cloudflare.com/cloudflare-one/access-controls/applications/http-apps/self-hosted-public-app/>
- Rate limiting rules: <https://developers.cloudflare.com/waf/rate-limiting-rules/>
- Tailscale Funnel: <https://tailscale.com/kb/1223/funnel>
