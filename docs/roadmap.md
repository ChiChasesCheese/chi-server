# Roadmap

The default setup is a minimal but complete core. These are ideas worth adding, with the reasons they are not in
the default yet. Every service you add is more to operate: add what you will use.

## Candidate modules

### AI hub

The Mac mini's most distinctive strength.

- **Always-on coding agents.** Run long agent sessions in `tmux` on the server and attach over SSH from anywhere;
  they keep running when your laptop sleeps.
- **Personal assistant agents.** Agents that read mail or messages and act on your behalf need broad
  permissions. If you run one: give it a separate standard macOS user, the smallest possible account and API
  scopes, never expose its admin UI publicly, and follow its security updates.
- **Local RAG.** Open WebUI's knowledge base already answers questions over your documents with local models.
- **Speech to text.** `whisper-cpp` runs natively with Metal; pair it with n8n to process recordings.

### Home Assistant

Not a container stack because Docker on macOS has no real host networking (mDNS/SSDP discovery fails) and no USB
pass-through for Zigbee/Thread dongles. The right approach is Home Assistant OS in a VM: UTM with bridged
networking and USB pass-through. A `homeassistant` module could automate the VM setup.

### DNS ad blocking (AdGuard Home)

Run it on the server and set it as the tailnet DNS (ad blocking on every device, even away from home) or as the LAN
DNS in your router. If it is the only DNS for the house, the house goes offline with the Mac: configure a fallback.
In a container it sees the VM gateway instead of client IPs, so prefer native or tailnet-only use.

### Time Machine server

System Settings -> General -> Sharing -> File Sharing -> add a folder on an external disk -> Advanced Options ->
"Share as a Time Machine backup destination". Other Macs at home back up to it, with no extra software. A
`chi` subcommand could automate it.

### Other self-hosted services

| Service | Purpose | Notes |
|---|---|---|
| Paperless-ngx | Scan, OCR and search paper documents | Uses Postgres; needs a dump step in backups |
| Syncthing | Device-to-device file sync without a cloud | Native via Homebrew |
| Beszel | Lightweight host monitoring | Its agent must run natively to see real host metrics |
| What's Up Docker | Notify about new image versions without auto-updating | Replaces archived Watchtower |
| Gitea / Forgejo | Self-hosted Git | Limited value if you already use a hosted forge |

## Platform improvements

- **Prettier names.** Optional Caddy module with DNS-01 wildcard certificates pointing at the Tailscale IP
  ([Remote access](remote-access.md#prettier-names)).
- **FileVault-on mode.** First-class support for mode B: a LAN jump-host helper for pre-boot SSH unlock and
  `authrestart`-based update flows.
- **Apple `container` runtime.** Re-evaluate once it supports compose natively.
- **Native Jellyfin option** for VideoToolbox hardware transcoding when serving many concurrent 4K streams.
- **Restore automation.** A `chi restore` command that wraps the restore drill.
- **Rename legacy identifiers.** Migrate `com.chi-service.*` launchd labels and the `chi-service` log directory
  with an automatic, reversible migration.

Proposals and pull requests are welcome; see [CONTRIBUTING.md](../CONTRIBUTING.md).
