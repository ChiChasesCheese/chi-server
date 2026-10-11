# automation: n8n

The `automation` stack runs [n8n](https://n8n.io), a self-hosted workflow automation tool: schedules,
webhooks, API calls, local LLM calls and notifications in one place.

| Service | Container | Local port | Tailnet URL |
|---|---|---|---|
| n8n | `chi-n8n` | 5678 | `https://<TS_FQDN>:8004` |

Approximate memory: 300 MB. Data: `$DATA_DIR/n8n`.

## Enable

```bash
# .env: add automation to CHI_STACKS
chi up automation
chi serve
```

Open `https://<TS_FQDN>:8004` and create the owner account.

## Configure

The compose file sets:

- `N8N_HOST=<TS_FQDN>`, `N8N_PROTOCOL=https`, `WEBHOOK_URL=https://<TS_FQDN>:8004/`, so webhook URLs shown in
  the editor are reachable on your tailnet.
- `N8N_ENCRYPTION_KEY` from `.env`. It encrypts every stored credential.
- `host.docker.internal`, so workflows can call host services such as Ollama
  (`http://host.docker.internal:11434`).

Typical uses:

- Scheduled: each morning, collect weather, calendar and RSS, summarise with a local model, push to your phone.
- Webhooks: receive events from GitHub, smart-home devices or iOS Shortcuts and fan them out.

## Operate

```bash
chi logs automation
chi update
```

`chi backup run` stops n8n briefly so its SQLite database is captured consistently.

## Public webhooks

Webhooks for third-party services must be reachable from the internet. Do not publish the n8n editor. Instead,
attach n8n to the public stack's network and publish only the webhook path behind Cloudflare Access with a
Bypass rule for `/webhook/`. See [public: exposing a service from another stack](public.md#exposing-a-service-from-another-stack).
For a quick test, `tailscale funnel` also works ([Remote access](../remote-access.md#tailscale-funnel)).

## Troubleshoot

| Symptom | Check |
|---|---|
| Webhook URLs show `localhost` | `TS_FQDN` was empty when the container was created. Run `chi init`, then `chi up automation`. |
| Saved credentials fail to decrypt | `N8N_ENCRYPTION_KEY` changed. Restore the original `.env` from backup. |

## Security notes

Losing `N8N_ENCRYPTION_KEY` invalidates every saved credential. It is backed up with `.env`
(`chi backup run`), but because the key sits on the same disk as the database, credentials are only as safe as
the machine itself.
