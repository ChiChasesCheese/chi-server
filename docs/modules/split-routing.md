# Split routing: send only selected sites through an upstream proxy

`chi proxy` runs [mihomo](https://wiki.metacubex.one/en/) (the Clash Meta core) natively on the Mac. It routes
**only a list of domains** through an upstream proxy provider and sends everything else directly. Devices on
your LAN or tailnet use the Mac as their proxy, so the subscription, rules and node selection are maintained in
one place.

The shipped rules implement one concrete use case: **watching region-locked mainland-China video sites from
abroad**. Sites such as Bilibili, iQiyi, Youku, Tencent Video, Mango TV and NetEase Music decide what you can
watch by the exit IP of their API requests, so only those domains go through a mainland-China exit node.
Replace the rules to route any other set of sites through any other region.

```
 TV box / projector / phone / laptop
        |  HTTP proxy -> <mac>:7890 (or PAC file)
        v
 mihomo on the Mac mini -- rule match by domain --+
        |                                        |
        | listed domains                         | everything else
        v                                        v
   upstream proxy node (auto-selected)         DIRECT
```

| Endpoint | Address | Published |
|---|---|---|
| Proxy (HTTP + SOCKS5) | `<mac-ip>:CLASH_PORT` (7890) | LAN and tailnet (allow-list below) |
| API / dashboard backend | `127.0.0.1:9090` | `https://<TS_FQDN>:8007/ui` via `chi serve` |

Why this design:

- **Split, not global**: the provider sees only the listed sites; slow upstream nodes do not slow everything.
- **Central proxy**: TV boxes need one proxy address instead of their own app and subscription.
- **Native, not containerised**: LAN devices must reach it directly; Homebrew ships a formula and `chi update`
  upgrades it.

## Requirements

An upstream provider that gives you a **Clash / Clash Meta subscription URL** with nodes in the region you need.
Providers that only ship their own apps cannot be used with mihomo; for TV-only use, such an app on the TV box
plus `chi tv vpn` may be simpler ([Android TV](android-tv.md)).

The provider can see the traffic routed through it. Do not use it as a global proxy for banking or email.

## Enable

```bash
cd ~/chi-server
open -e .env
#   CLASH_SUBSCRIPTION_URL='https://...'   always single-quoted (URLs contain &)
#   CLASH_CN_FILTER='...'                  regex selecting nodes; '.*' if all nodes are in the target region
bin/chi init            # generates CLASH_SECRET if missing
bin/chi proxy install   # install mihomo, render config, start, allow in firewall, self-test
bin/chi proxy test
bin/chi serve           # dashboard at https://<TS_FQDN>:8007/ui
```

`chi proxy test` asks a geo-IP endpoint (Bilibili's) where you are, directly and through the proxy, and passes
when the proxied exit is mainland China. If you change the target region, use your own check instead.

Dashboard (metacubexd): on first open, set the backend to `https://<TS_FQDN>:8007` and the secret to
`CLASH_SECRET`. From there you can watch connections, pick nodes, or switch the `CN-media` group to `DIRECT` to
disable routing temporarily.

## Configure

The template is `config/mihomo/config.yaml.tmpl`; `chi proxy apply` renders it to
`$(brew --prefix)/etc/mihomo/config.yaml` (mode 600, contains the subscription URL) and validates it with
`mihomo -t` before restarting.

| Part | Default |
|---|---|
| `proxy-providers.cn-vpn` | Your subscription, refreshed every 6 hours, filtered by `CLASH_CN_FILTER`, health-checked against a 204 endpoint reachable from the target region. |
| Group `CN` | `url-test`: picks the lowest-latency node. |
| Group `CN-media` | `select`: `CN` or `DIRECT`. |
| Rules | LAN, tailnet (`100.64.0.0/10`) and OrbStack (`198.18.0.0/15`) ranges go direct; GEOSITE `bilibili`, `iqiyi`, `youku` and domain suffixes for Tencent Video, NetEase Music, Mango TV, CCTV and TV-client domains go to `CN-media`; `MATCH,DIRECT`. |
| `lan-allowed-ips` | Loopback, private ranges, Tailscale CGNAT range and OrbStack's range only, so an accidental port forward does not make it an open proxy. |

To route other sites, add rules above `MATCH,DIRECT`, for example `- DOMAIN-SUFFIX,example.com,CN-media`, then:

```bash
bin/chi proxy apply
```

If you also use the PAC file (below), add the same domains to `config/onboarding/chi.pac.tmpl` and run
`chi onboard`.

## Point devices at it

| Device | How |
|---|---|
| Android TV / Google TV | `chi tv connect <ip>` then `chi tv proxy <ip> on` (many TV settings menus have no proxy option). Off: `chi tv proxy <ip> off`. |
| TV / projector with a proxy setting | Wi-Fi settings -> proxy -> manual -> Mac LAN IP, port 7890. |
| Laptop or phone at home | HTTP proxy -> manual -> Mac LAN IP, port 7890; or the PAC URL. |
| Laptop or phone anywhere | With Tailscale on, use the PAC file: `https://<TS_FQDN>:8008/chi.pac` (from `chi onboard`). It proxies only the listed domains, via the Mac's Tailscale IP. |
| MeTube (media stack) | Automatic: `chi up media` routes MeTube through mihomo when it is listening. |

Limitations:

- When the Mac is off or mihomo is down, devices with a global proxy setting lose internet access. Clear the
  setting (`chi tv proxy <ip> off`).
- iOS cannot set a proxy on cellular, and runs one VPN app at a time.
- Some apps ignore the system proxy. On Android, a Clash Meta client on the device itself (importing the same
  subscription) captures all traffic through the VPN interface.

## Downloading region-locked videos

yt-dlp supports many such sites. Through the proxy:

```bash
yt-dlp --proxy http://127.0.0.1:7890 --cookies cookies.txt '<url>'
```

Or simply `chi fetch <url>` with the media stack: MeTube already uses the proxy. Some sites cap quality without
login cookies (upload a cookies file in MeTube).

## Operate

```bash
chi proxy status     # service + selected node
chi proxy logs
chi proxy apply      # after editing .env or the template
chi update           # upgrades mihomo, re-allows it in the firewall, restarts it
chi proxy uninstall
```

`chi doctor` checks the proxy whenever `CLASH_SUBSCRIPTION_URL` is set.

## Troubleshoot

| Symptom | Check |
|---|---|
| `chi proxy test` still shows your home country | `chi proxy status`: if the `CN` group has 0 nodes, `CLASH_CN_FILTER` matches nothing. Look at real node names in the dashboard and fix the regex. |
| Devices cannot connect after a Homebrew upgrade | The binary path changed: `chi proxy firewall` (`chi update` does this). |
| A TV box has no internet | `chi proxy status` on the Mac; temporarily `chi tv proxy <ip> off`. |
| An app still reports a region restriction | It bypasses the system proxy (use an on-device client), or uses a domain not in the rules (find it in the dashboard's Connections view and add it). |
| Subscription update fails | `chi proxy logs`. Some providers require a specific User-Agent: add a `header` to the provider in the template. |
| Video is slow | Rules match CDN domains too, so video also goes through the upstream node. You can try sending CDN domains `DIRECT`, but some streams are bound to the requesting IP and will fail. |

## Deliberately not done

- **Transparent gateway (TUN mode)** on the Mac: devices would need no proxy settings, but it competes with
  Tailscale for the routing table, and a failure takes the whole home offline.
- **Rooting devices or third-party unlock modules** that route your account credentials through unknown
  servers.

Using a proxy to bypass regional restrictions may violate a platform's terms of service; the worst case is
usually account restrictions.
