# photos: Immich

The `photos` stack runs [Immich](https://immich.app), a self-hosted Google Photos alternative with mobile
backup, face recognition and semantic search.

| Service | Container | Local port | Tailnet URL |
|---|---|---|---|
| Immich server | `immich_server` | 2283 | `https://<TS_FQDN>:8006` |
| Machine learning, Postgres, Redis | upstream names (`immich_postgres`, ...) | internal | - |

Approximate memory: 2-4 GB. Needs plenty of disk. Not recommended on 16 GB / 256 GB machines.

## How the stack differs

Immich's compose file changes often and couples server, ML and Postgres versions, so it is **not vendored**.

- `stacks/photos/fetch.sh` downloads the latest released `docker-compose.yml` as `compose.yaml` and
  `example.env`, and creates `stacks/photos/.env` with a random `DB_PASSWORD`.
- On every run it syncs `UPLOAD_LOCATION=$DATA_DIR/immich/library`,
  `DB_DATA_LOCATION=$DATA_DIR/immich/postgres` and `TZ`.
- `compose.override.yaml` (committed) rebinds the port to `${BIND_ADDR}:2283` instead of `0.0.0.0`. It uses
  `!override`, which needs Docker Compose 2.24 or newer.
- `pre-up.sh` runs `fetch.sh`, so `chi up photos` handles the first download.

## Enable

```bash
# .env: add photos to CHI_STACKS
chi up photos
chi serve
```

Open `https://<TS_FQDN>:8006` and create the admin account. On phones, install the Immich app, use the same
URL as the server, and enable background backup.

## Configure

- Photos live in `$DATA_DIR/immich/library`. For a large library, move `DATA_DIR` (or just the library) to an
  external SSD: APFS, mounted at boot. Do not put the database on a USB hard drive.
- Immich machine learning runs CPU-only in the container. First indexing of tens of thousands of photos can
  take a day or two; increments are fast afterwards.

## Operate

Upgrades can contain breaking changes. `chi update` pulls images but does not refresh the compose file. To
upgrade, read the Immich release notes, then:

```bash
stacks/photos/fetch.sh --force     # re-download compose.yaml; keeps the DB password in .env
chi up photos
```

Backups: `chi backup run` dumps the database online with `pg_dumpall` into `$DATA_DIR/immich/db-dump` and backs
up the library and dump without stopping Immich (tag `photos`). The raw Postgres directory is excluded.

To restore the database, start only the database container, import the SQL dump, then start the rest. Follow
Immich's official "Backup and Restore" documentation for your version.

## Troubleshoot

| Symptom | Check |
|---|---|
| `compose.yaml not found` | Run `stacks/photos/fetch.sh` (needs network access to GitHub). |
| `!override` error | Upgrade Docker Compose (OrbStack and current Colima installs ship a recent one). |
| Homepage card says not running | The container is `immich_server` (upstream name), not `chi-...`. |
