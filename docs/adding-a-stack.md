# Adding a stack

A stack is a directory under `stacks/`. `bin/chi` discovers stacks automatically; you do not edit any script to
add one. This walkthrough adds a hypothetical `notes` stack serving a web app on container port 80.

## 1. Create the directory

```bash
mkdir stacks/notes
```

## 2. Write `compose.yaml`

```yaml
# notes: a short description of what this stack is and why it exists.

services:
  notes:
    image: example/notes:1.2.3
    container_name: chi-notes
    restart: unless-stopped
    ports:
      - "${BIND_ADDR:-127.0.0.1}:8300:80"
    environment:
      TZ: "${TZ}"
      BASE_URL: "https://${TS_FQDN:-localhost}:8011"
      SECRET_KEY: "${NOTES_SECRET_KEY}"
    volumes:
      - ${DATA_DIR}/notes:/data
```

Conventions:

| Convention | Why |
|---|---|
| `container_name: chi-<service>` | Predictable names for `docker exec`, Homepage and Kuma. |
| `restart: unless-stopped` | Containers come back after the runtime restarts at login. |
| Ports bound to `${BIND_ADDR:-127.0.0.1}` | Only `tailscale serve` reaches them by default. |
| Pick a free local port | Check existing `compose.yaml` files and `stack.conf` `SERVE` values. |
| Variables from the root `.env` | Every compose call passes `--env-file .env`; reference keys as `${KEY}`. |
| Data under `${DATA_DIR}/<service>` | One directory to back up and restore. Never store data in the repo. |
| URLs from `${TS_FQDN:-localhost}` | Links and callbacks match the tailnet name. `chi doctor` flags stale `localhost` values for known variables. |
| `extra_hosts: ["host.docker.internal:host-gateway"]` | Only if the service must reach host services (Ollama, mihomo); needed for Colima. |
| No `docker.sock` | Unless the service is a read-only dashboard; socket access is root on the VM. |

The compose project will be `chi-notes`; networks and volumes get that prefix.

If the service needs a new secret, add it to `.env.example` (empty, under "Service secrets") and, if it should be
generated, to the `fill_if_empty` calls in `scripts/init-env.sh`. Then run `chi init`.

## 3. Write `stack.conf`

```bash
# Stack manifest (sourced by scripts/lib.sh). Keep it to plain KEY="value" lines.
DESCRIPTION="Notes app"
SERVE="8011=8300"
```

`SERVE` maps HTTPS port 8011 on the tailnet to `127.0.0.1:8300`. Use an empty `SERVE=""` if the stack should not
be published on the tailnet. Tailnet HTTPS ports currently in use: 443 and 8001-8010.

## 4. Optional hooks

- **`pre-up.sh`** (executable) runs before `chi up` for this stack. Use it to create directories, check host
  dependencies, or generate `stacks/<name>/.env` (for example `COMPOSE_PROFILES`). Source `scripts/lib.sh` for
  `log`, `ok`, `warn`, `die` and `load_env`. Generated `.env` files are ignored by git and passed to compose
  automatically, before the root `.env`.

  ```bash
  #!/usr/bin/env bash
  # Before `chi up notes`: create the data directory.
  set -euo pipefail
  . "$(dirname "$0")/../../scripts/lib.sh"
  load_env
  mkdir -p "$DATA_DIR/notes"
  ```

- **`fetch.sh`** (executable) produces `compose.yaml` from upstream when it is not vendored (see `stacks/photos/`).
  `chi` runs it when `compose.yaml` is missing. Add the downloaded files to `.gitignore`.
- **`compose.override.yaml`** is merged after `compose.yaml`. Use it to adjust an upstream file without editing it.

## 5. Homepage entry

Add a card to `stacks/core/homepage/services.yaml`:

```yaml
    - Notes:
        icon: mdi-note-text
        href: https://{{HOMEPAGE_VAR_TS_FQDN}}:8011
        description: Notes
        server: local
        container: chi-notes
```

Reload Homepage; no restart needed.

## 6. Monitoring and backup

- Add an Uptime Kuma HTTP monitor for `http://host.docker.internal:8300/`, or extend the list in
  `scripts/kuma-seed.sh`.
- `chi backup run` stops every enabled stack (except `photos`) while it snapshots `DATA_DIR`, so SQLite-based
  apps are captured consistently without changes. If your service uses a server database (Postgres, MySQL), add an
  online dump step to `scripts/backup.sh` instead.

## 7. Documentation

Add `docs/modules/<name>.md` with the same sections as the existing pages: what it is, ports and URLs, enable,
configure, operate, troubleshoot, security notes. Link it from the feature table in `README.md`. Mention the new
stack in the `CHI_STACKS` comment in `.env.example`.

## 8. Enable and test

```bash
chi stacks                 # the new stack is listed with its description
chi up notes
chi serve                  # if notes is in CHI_STACKS
chi ps notes
chi doctor
```

`chi up notes` works without adding it to `CHI_STACKS`; add it there so `chi up`, `chi serve`, `chi update`,
`chi backup` and `chi doctor` include it by default.

## 9. CI

The lint workflow picks the stack up automatically: it runs `shellcheck -x` on `stacks/*/*.sh` and
`docker compose config` on every `stacks/*/compose.yaml` with a `.env` derived from `.env.example`. Make sure any
new variable your compose file needs without a default exists in `.env.example`. Run the same checks locally before
opening a pull request ([CONTRIBUTING.md](../CONTRIBUTING.md)).
