# core: dashboard, monitoring, logs

The `core` stack is the baseline every server should run.

| Service | Container | Local port | Tailnet URL |
|---|---|---|---|
| Homepage (dashboard) | `chi-homepage` | 3000 | `https://<TS_FQDN>` |
| Uptime Kuma (monitoring, alerts) | `chi-uptime-kuma` | 3001 | `https://<TS_FQDN>:8001` |
| Dozzle (live container logs, read-only) | `chi-dozzle` | 8080 | `https://<TS_FQDN>:8002` |

Approximate memory: 300 MB.

## Enable

`core` is in the default `CHI_STACKS`.

```bash
chi up core
chi serve
```

## Configure

### Homepage

Configuration lives in the repository at `stacks/core/homepage/*.yaml` (`services.yaml`, `widgets.yaml`,
`settings.yaml`, `bookmarks.yaml`, `docker.yaml`). Edits take effect on page reload; no restart needed.

- Links use `{{HOMEPAGE_VAR_TS_FQDN}}`, so they follow `TS_FQDN`.
- The Jellyfin card shows library counts and now playing when `JELLYFIN_API_KEY` is set.
- The public card links to `PUBLIC_DOMAIN`.
- Cards for stacks you do not run show as not running. Delete them from `services.yaml` if you prefer.
- The resources widget shows the container VM, not the Mac. Use `btop` over SSH for host load.
- `HOMEPAGE_ALLOWED_HOSTS` is set from `TS_FQDN`, `localhost:3000`, `127.0.0.1:3000` and
  `<CHI_HOSTNAME>.local:3000`. Homepage rejects other Host headers.

### Uptime Kuma

Create the admin account on first visit. Then seed default monitors and an ntfy notification:

```bash
scripts/kuma-seed.sh                       # prompts for username and password
```

It adds HTTP checks for Homepage (through Tailscale HTTPS, which also watches certificate expiry), Jellyfin,
Open WebUI, MeTube, Ollama, Dozzle and an internet reachability check. Re-running skips monitors that already
exist. See [Operations: alerts](../operations.md#alerts) for the non-interactive mode and ntfy setup.

To add monitors by hand, target `http://host.docker.internal:<local-port>` from inside Kuma. A monitor without a
notification channel is not a monitor: configure at least one under Settings -> Notifications.

### Dozzle

Nothing to configure. It reads the Docker socket read-only.

## Operate

```bash
chi ps core
chi logs core uptime-kuma
chi restart core
```

Uptime Kuma runs on the machine it monitors. If the whole Mac goes down, so does Kuma. Set `HC_PING_URL` for an
external heartbeat ([Operations](../operations.md#heartbeat)).

## Troubleshoot

| Symptom | Check |
|---|---|
| Homepage rejects the request (host validation error) | You are using a hostname not in `HOMEPAGE_ALLOWED_HOSTS`. Use `https://<TS_FQDN>`; if `TS_FQDN` changed, run `chi up core`. |
| Homepage cards show "API error" for Jellyfin | `JELLYFIN_API_KEY` is empty or wrong. |
| `kuma-seed.sh` login fails repeatedly | Kuma rate-limits logins; wait a minute. 2FA accounts are not supported by the script. |
| Forgot the Kuma password | See [Operations: Uptime Kuma](../operations.md#uptime-kuma). Never reset it inside the running container. |

## Security notes

All three services mount `/var/run/docker.sock` read-only. Access to the Docker socket is effectively root on
the container VM. Never publish these services to the internet.
