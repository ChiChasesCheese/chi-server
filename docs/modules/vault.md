# vault: Vaultwarden

The `vault` stack runs [Vaultwarden](https://github.com/dani-garcia/vaultwarden), a lightweight
Bitwarden-compatible server. All official Bitwarden apps and browser extensions work with it.

| Service | Container | Local port | Tailnet URL |
|---|---|---|---|
| Vaultwarden | `chi-vaultwarden` | 8222 | `https://<TS_FQDN>:8005` |

Approximate memory: 50 MB. Data: `$DATA_DIR/vaultwarden`.

Vaultwarden must be served over HTTPS (browsers expose WebCrypto only in secure contexts), so use it only
through `chi serve`.

## Enable and create accounts

1. Add `vault` to `CHI_STACKS`, set `VAULTWARDEN_SIGNUPS_ALLOWED=true` in `.env`.
2. Start and publish:

   ```bash
   chi up vault
   chi serve
   ```

3. Open `https://<TS_FQDN>:8005` and register your account (and family members').
4. Set `VAULTWARDEN_SIGNUPS_ALLOWED=false` and apply:

   ```bash
   chi up vault
   ```

5. In the Bitwarden apps, choose self-hosted and enter `https://<TS_FQDN>:8005` as the server URL.

## Configure

- The admin panel is disabled because `ADMIN_TOKEN` is not set. If you need it, generate a hash with
  `docker exec -it chi-vaultwarden /vaultwarden hash` and add `ADMIN_TOKEN` to the compose environment.
- `DOMAIN` is set from `TS_FQDN`.

## Operate

```bash
chi logs vault
chi update
```

`chi backup run` stops Vaultwarden briefly to snapshot its SQLite database consistently.

## Troubleshoot

| Symptom | Check |
|---|---|
| Clients cannot connect | The device must be on the tailnet. Check `https://<TS_FQDN>:8005` in a browser. |
| Registration is disabled | Expected after step 4. Toggle `VAULTWARDEN_SIGNUPS_ALLOWED` temporarily. |

## Security notes

When you self-host your password manager, you are its operator. Vault data is encrypted client-side, but if
the machine dies without a working backup, the vault is gone (clients keep an offline cache; do not rely on
it). Run a restore drill before you depend on it ([Operations](../operations.md#restore-drill)).

Do not store the restic password only in this Vaultwarden instance: you would need the vault to restore the
vault.
