# Operations

Day-2 tasks: keeping the server running unattended, updating it, alerting, backups, scheduled jobs, logs and
troubleshooting.

## Routine

| When | What |
|---|---|
| Daily (automatic) | `chi backup run`, media cleanup, IPTV refresh, heartbeat (launchd, via `chi schedule`) |
| Every 1-2 weeks | `chi update`, then `chi doctor` (or `chi remote-check` from your laptop) |
| Monthly | `chi backup check`; glance at `chi backup snapshots` |
| Quarterly | [Restore drill](#restore-drill) |
| macOS updates | [OS upgrades](#os-upgrades) |
| Every 90 days | Renew the Tailscale API token if you use `scripts/friend-ts.sh` |

## Unattended mode

The Docker runtime and Ollama start only when a user logs in, and macOS does not allow auto-login while
FileVault is on. So you have to choose:

| Mode | After a power cut or reboot | Cost |
|---|---|---|
| **A: FileVault off + auto-login** (what `chi unattended` sets up) | Comes back on its own | A stolen disk is readable; the login password is stored reversibly |
| **B: FileVault on** | Stops at the unlock screen until someone unlocks it | Planned reboots need `sudo fdesetup authrestart`; unplanned ones need LAN access |

Mode A suits a server at home that must "just be there" while you travel. Choose mode B if you have a LAN jump
host (Raspberry Pi, NAS, router with Tailscale) and a UPS, or the data is particularly sensitive. Either way, keep
backups: disk failure and theft are more likely than intrusion. Trade-offs: [Security](security.md#filevault-and-auto-login).

### Mode A: `chi unattended`

```bash
ssh -t chi-mini 'cd ~/chi-server && bin/chi unattended'
```

It needs an interactive terminal (it asks for passwords) and is safe to re-run; finished steps are skipped.

1. **Tailscale operator and serve rules.** Sets your user as Tailscale operator (`chi serve` then needs no
   sudo) and applies all serve rules, including the onboarding page.
2. **FileVault off.** Runs `fdesetup disable` (enter your username and login password). On Apple Silicon this
   finishes quickly; decryption may continue in the background. Success is judged by `fdesetup status`, not the
   exit code. If it fails, use System Settings -> Privacy & Security -> FileVault.
3. **Auto-login.** Once FileVault is off, runs `sysadminctl -autologin set`. It then **verifies** that auto-login
   is effective: `autoLoginUser` must be set, `/etc/kcpassword` must exist, and `sysadminctl -autologin status`
   must not report it off. Setting only `autoLoginUser` (for example with a wrong password) leaves the Mac at
   the login window. If verification fails, use System Settings -> Users & Groups -> Automatically log in as.
   If FileVault is still decrypting, this step is skipped: run the command again later.
4. **Lock at login.** Requires the password immediately after screensaver or display sleep, and installs
   `~/Library/LaunchAgents/com.chi-service.lock-at-login.plist`, which starts the screensaver and sleeps the
   display 3 seconds after login. Login items and services still start; the desktop is locked.

Verify with `chi doctor` (FileVault and auto-login lines), then reboot and run `chi remote-check` from your
laptop.

### Mode B: FileVault on

- **Planned reboots**: always use `sudo fdesetup authrestart`. It pre-authorises one unlock, so the Mac unlocks
  and logs in automatically.
- **Unplanned reboots**: macOS 26 supports SSH unlock at the pre-boot stage. From the LAN only (Tailscale is not
  running yet): `ssh <server-username>@<lan-ip>` with your account password; ignore the different host key
  (the pre-boot environment has its own). If it stops at the login window afterwards, log in once over screen
  sharing.
- It is unverified whether key-only SSH (`CHI_SSH_KEY_ONLY=1`) breaks pre-boot unlock, which uses a password. If
  you enable both, test a reboot while you are next to the machine.
- `chi bootstrap macos` already disables automatic installation of macOS updates, which would otherwise reboot
  into the unlock screen.

### Passwordless reboot

To let your laptop (or an automation) reboot the server without a password, allow only commands whose worst
outcome is a reboot. Replace `<you>` with the server account:

```bash
ssh -t chi-mini 'echo "<you> ALL=(root) NOPASSWD: /sbin/shutdown, /sbin/reboot, /usr/bin/fdesetup authrestart, /usr/bin/pmset" \
  | sudo tee /etc/sudoers.d/chi-ops >/dev/null \
  && sudo chmod 440 /etc/sudoers.d/chi-ops \
  && sudo visudo -cf /etc/sudoers.d/chi-ops'
```

Then:

```bash
ssh chi-mini 'sudo -n /sbin/shutdown -r now'
# after it comes back, from the laptop:
bin/chi remote-check
```

Do not add `tailscale` to this list: operator rights are enough, and sudo on `tailscale` would allow
`tailscale funnel` to open services to the internet.

## Updates

### Containers and Homebrew

```bash
chi update            # brew upgrade + pull images + recreate containers + prune old images
chi update --no-brew  # containers only
chi doctor
```

Read release notes first, especially for Immich (`photos`): `chi update` does not refresh its compose file; see
[photos](modules/photos.md#operate).

### Changing configuration

```bash
cd ~/chi-server
git pull              # if you changed the repo elsewhere
bin/chi init          # adds keys that are new in .env.example
bin/chi up            # compose recreates only containers whose config changed
bin/chi serve         # only if ports changed
bin/chi schedule      # only if schedule-related keys changed
```

### OS upgrades

`chi bootstrap macos` auto-downloads updates and auto-installs security responses and XProtect data, but not
macOS updates. Install those by hand:

```bash
chi backup run                  # back up first
softwareupdate --list
sudo softwareupdate -i -a       # download and install, no reboot
sudo shutdown -r now            # FileVault off; with FileVault on: sudo fdesetup authrestart
# afterwards
chi doctor
```

After a major upgrade, re-run `chi bootstrap macos` (settings occasionally reset) and `chi doctor`.

## Alerts

Three layers, from inside to outside:

| Layer | Detects | Configure |
|---|---|---|
| `chi doctor` / `chi remote-check` | Anything, when you run it | Nothing |
| Uptime Kuma + ntfy | A service down while the Mac is up | `NTFY_TOPIC`, `scripts/kuma-seed.sh` |
| healthchecks.io heartbeat | The whole Mac or its internet down | `HC_PING_URL`, `chi schedule` |

### ntfy

`chi init` generates `NTFY_TOPIC=chi-<random>`. Install the ntfy app on your phone and subscribe to that topic on
`ntfy.sh` (or your own server, set `NTFY_SERVER`). On the public server the topic name is effectively the
password: anyone who knows it can read and post. Keep it random.

### Uptime Kuma

Create the Kuma admin account in the web UI first, then seed monitors and the ntfy notification:

```bash
scripts/kuma-seed.sh                    # prompts for username and password on the terminal
```

Non-interactive mode (for automation over SSH): put the password in a file only you can read and pass the
username as the first argument:

```bash
(umask 077 && cat > ~/.config/chi/kuma-password)      # paste, Enter, Ctrl-D
KUMA_PASSWORD_FILE=~/.config/chi/kuma-password scripts/kuma-seed.sh <kuma-user>
```

The script logs in normally over Kuma's socket API from inside the container, creates or updates an ntfy
notification marked as default (if `NTFY_TOPIC` is set), and adds monitors that do not exist yet: Homepage over
Tailscale HTTPS (with certificate expiry alerts), Jellyfin, Open WebUI, MeTube, Ollama, Dozzle and an internet
check. It is idempotent. Accounts with 2FA are not supported. Do not feed passwords through a pty (`script`), which
echoes them.

**Resetting a forgotten Kuma password.** Never run Kuma's `reset-password` inside the running container: it
competes with the live server for the database (the v2 image can run an embedded MariaDB inside the container, which
must not be disturbed). Stop the container and use a one-off container on the same data instead:

```bash
docker stop chi-uptime-kuma
# put the new password in a file first (umask 077), so it never appears in shell history or a transcript
docker run --rm -v "$DATA_DIR/uptime-kuma:/app/data" louislam/uptime-kuma:2 \
  node extra/reset-password.js --new-password="$(cat ~/.config/chi/kuma-password)"
chi up core
```

(`DATA_DIR` is the value from `.env`.)

### Heartbeat

Kuma cannot alert you when the Mac itself is down. Create a check at [healthchecks.io](https://healthchecks.io)
(5-minute period, a few minutes of grace), put its ping URL in `HC_PING_URL`, and run:

```bash
chi schedule
```

This installs `com.chi-service.heartbeat`, which pings every 5 minutes. When pings stop (power, network, freeze),
healthchecks.io alerts you by email or push.

## Backups

Optional, but strongly recommended. Uses [restic](https://restic.net): incremental, deduplicated, encrypted;
local disk, B2, S3/R2 or SFTP.

```bash
# .env: RESTIC_REPOSITORY=/Volumes/Backup/restic-chi  (or b2:..., s3:...; set provider credentials too)
chi backup init
chi backup run
chi schedule          # daily at BACKUP_HOUR:17
```

Leaving `RESTIC_REPOSITORY` empty disables backups; `chi schedule` then does not install the backup job.

What `chi backup run` does:

1. Dumps Immich's Postgres online with `pg_dumpall` (if running).
2. Stops every enabled stack except `photos` (SQLite-based apps copied mid-write produce corrupt databases),
   backs up `$DATA_DIR` excluding `immich/`, `MEDIA_DIR` and Jellyfin's cache (tag `apps`), and restarts the
   stacks. A trap restarts them even on failure. Incremental runs usually take seconds to a minute.
3. Backs up the Immich library and database dump online (tag `photos`).
4. Backs up `.env` (tag `config`): it holds the n8n encryption key and other secrets.
5. Prunes: 7 daily, 4 weekly, 6 monthly snapshots per host and tag.

Not in the backup: the restic password (keep it in a password manager, and not only in your self-hosted
Vaultwarden), Ollama models (re-downloadable), media files (re-downloadable).

Follow 3-2-1: three copies, two media, one off-site. A practical setup is Time Machine to an external disk for the
whole Mac plus restic to B2/R2 for service data.

### Restore drill

The same procedure rebuilds the server on a new Mac.

```bash
# 1. On the new Mac
git clone https://github.com/ChiChasesCheese/chi-server.git ~/chi-server && cd ~/chi-server
mkdir -p ~/.config/chi && pbpaste > ~/.config/chi/restic-password     # from your password manager
export RESTIC_REPOSITORY=<your-repo> RESTIC_PASSWORD_FILE=~/.config/chi/restic-password
# (plus B2_* or AWS_* credentials for cloud repositories)

# 2. Restore .env and data to their original paths (if paths differ, fix DATA_DIR in .env afterwards)
restic snapshots
restic restore latest --tag config --target /
restic restore latest --tag apps   --target /
restic restore latest --tag photos --target /     # if you use photos

# 3. Provision and start
bin/chi bootstrap
bin/chi up

# 4. Immich: start only the database, import the SQL dump, then start everything
#    (follow Immich's "Backup and Restore" docs for your version)
```

For a drill, restore into a scratch directory (`--target /tmp/restore-test`), check the files are there and the
SQLite databases open. Do not overwrite production.

## Scheduled jobs

```bash
chi schedule              # install / refresh
chi schedule uninstall    # remove all
launchctl kickstart -k gui/$(id -u)/com.chi-service.backup     # run the backup job now
launchctl list | grep com.chi-service
```

| Label | Schedule | Log |
|---|---|---|
| `com.chi-service.backup` | daily `BACKUP_HOUR`:17 | `~/Library/Logs/chi-service/backup.log` |
| `com.chi-service.media-clean` | daily 05:47 | `~/Library/Logs/chi-service/media-clean.log` |
| `com.chi-service.media-iptv` | daily 05:27 | `~/Library/Logs/chi-service/media-iptv.log` |
| `com.chi-service.heartbeat` | every 5 minutes | none |
| `com.chi-service.lock-at-login` | at login (from `chi unattended`) | none |

The `com.chi-service.*` labels and the `chi-service` log directory are legacy names kept for compatibility with
existing installs.

## Logs

| What | Where |
|---|---|
| A stack | `chi logs <stack> [service]`, or Dozzle at `https://<TS_FQDN>:8002` |
| Scheduled jobs | `~/Library/Logs/chi-service/<job>.log` |
| mihomo | `chi proxy logs` |
| Tailscale daemon | `sudo log show --predicate 'process == "tailscaled"' --last 1h` |
| Host load | `btop` over SSH (Homepage shows the container VM, not the Mac) |

## Troubleshooting

| Symptom | Check |
|---|---|
| Nothing loads | `chi doctor`; `tailscale status`; is OrbStack running? After a reboot, did auto-login happen? |
| One service does not load | `chi ps <stack>`; `chi logs <stack>`. |
| Services did not come back after a reboot | Auto-login not effective (`chi doctor`; re-run `chi unattended`), or OrbStack "Start at login" is off. |
| Public site shows Cloudflare error 1033 (or 530) | cloudflared is not connected. Usually the Mac rebooted and nobody is logged in, so the runtime never started. Fix auto-login. Otherwise `chi logs public cloudflared`. |
| `chi remote-check` warns "DERP" / relayed | No direct path. Forward UDP 41641 to the Mac on your router; check `tailscale netcheck`. |
| `chi serve` certificate errors | HTTPS Certificates enabled in the Tailscale DNS settings? `TS_FQDN` correct (`chi init`)? |
| Containers still use `localhost` URLs | `TS_FQDN` was empty when they were created: `chi init`, then `chi up`. `chi doctor` lists them. |
| Node dropped off the tailnet after months | Key expiry: disable it for this machine in the admin console and re-authenticate. |
| LAN IP keeps changing despite a DHCP reservation | Some ISP gateways ignore reservations for devices already online, or the Mac uses a private (rotating) Wi-Fi MAC address. Turn off Private Wi-Fi Address for the network, or pin the address on the Mac with `networksetup -setmanualwithdhcprouter Wi-Fi <ip>` (undo with `networksetup -setdhcp Wi-Fi` when you change routers). On Ethernet, use the `Ethernet` service name. |
| Permission errors writing data (Colima) | `chmod -R u+rwX,g+rwX "$DATA_DIR/<service>"`, or switch to OrbStack. |
| Backup works by hand but fails in launchd | Read `~/Library/Logs/chi-service/backup.log`. For external disks, grant Full Disk Access to `/bin/bash` and `/opt/homebrew/bin/restic`. |
| Backup says repository unavailable | External disk not mounted, or `chi backup init` not run. |
| Ollama is slow | `ollama ps`: the model is partly on the CPU; use a smaller one. |
| Disk full | `chi media`; `docker system df`; `docker image prune -a`. OrbStack reclaims VM disk space automatically. |
| LAN devices cannot use the proxy after `brew upgrade` | `chi proxy firewall`. |
| Forgot the Uptime Kuma password | [Reset with a one-off container](#uptime-kuma), never inside the running one. |
