#!/usr/bin/env bash
# Add a default set of monitors to Uptime Kuma (per-service health checks + internet). Prompts for the Kuma
# username/password and logs in normally.
# Usage: scripts/kuma-seed.sh [username]
#        KUMA_PASSWORD_FILE=~/.config/chi/kuma-password scripts/kuma-seed.sh <username>   (non-interactive)
# Idempotent: a monitor whose name already exists is skipped, so re-running adds nothing twice.
# Optional: with NTFY_TOPIC set in .env (and optionally NTFY_SERVER, default https://ntfy.sh), creates an ntfy
#           notification (set as default) and attaches it to the monitors added in this run. Subscribe to the same
#           topic in the ntfy phone app to receive alerts.
#           Note: on the public ntfy.sh server the topic name IS the password - anyone who knows it can subscribe,
#           so pick something hard to guess.
# Credentials are read from /dev/tty; the JS goes into the container via docker cp and stdin carries only the
# password; 20s timeout per call, 60s overall.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
load_env
ensure_brew_path
docker ps --format '{{.Names}}' | grep -qx chi-uptime-kuma || die "chi-uptime-kuma is not running -> chi up core"

user="${1:-}"
# Non-interactive: KUMA_PASSWORD_FILE points at a password file only you can read (e.g. ~/.config/chi/kuma-password);
# the username is the first argument. Don't feed the password into /dev/tty via script/pty - the pty echoes input.
if [ -n "${KUMA_PASSWORD_FILE:-}" ]; then
  [ -n "$user" ] || die "With KUMA_PASSWORD_FILE, pass the username as the first argument"
  [ -r "$KUMA_PASSWORD_FILE" ] || die "Cannot read $KUMA_PASSWORD_FILE"
  pass="$(head -n1 "$KUMA_PASSWORD_FILE")"
else
  { : </dev/tty; } 2>/dev/null || die "Run this in an interactive terminal (cannot read /dev/tty), or set KUMA_PASSWORD_FILE"
  [ -n "$user" ] || read -r -p "Uptime Kuma username: " user </dev/tty
  IFS= read -r -s -p "Uptime Kuma password: " pass </dev/tty; echo >&2
fi
[ -n "$user" ] || die "Username is empty"
[ -n "$pass" ] || die "Password is empty"

js_local="$(mktemp "${TMPDIR:-/tmp}/chi-kuma-seed.XXXXXX")"
js_remote="/tmp/chi-kuma-seed.$$.js"
# shellcheck disable=SC2329  # invoked via trap
cleanup() {
  rm -f "$js_local"
  # Only delete the script we copied in; never kill processes in the Kuma container (it would take the embedded MariaDB down too)
  docker exec chi-uptime-kuma rm -f "$js_remote" >/dev/null 2>&1 || true
}
trap cleanup EXIT

cat >"$js_local" <<'JS'
const { io } = require("/app/node_modules/socket.io-client");
const fs = require("fs");

const CALL_TIMEOUT = 20000; // per call
const TOTAL_TIMEOUT = 60000; // overall
const t0 = Date.now();
const say = (m) => console.log(`   [${((Date.now() - t0) / 1000).toFixed(1)}s] ${m}`);
const fail = (m) => { console.error(` ✗ ${m}`); process.exit(1); };
setTimeout(() => fail(`Overall timeout (${TOTAL_TIMEOUT / 1000}s): Kuma not responding. See docker logs --tail 50 chi-uptime-kuma`), TOTAL_TIMEOUT).unref();

const password = fs.readFileSync(0, "utf8"); // password comes from stdin (printf on the bash side, no trailing newline)
const { KUMA_USER, TS_FQDN = "", NTFY_TOPIC = "", NTFY_SERVER = "" } = process.env;

const base = {
  type: "http", method: "GET", interval: 60, retryInterval: 60, resendInterval: 0, maxretries: 2, timeout: 48,
  notificationIDList: {}, accepted_statuscodes: ["200-299"], conditions: [], kafkaProducerBrokers: [],
  kafkaProducerSaslOptions: { mechanism: "None" }, rabbitmqNodes: [], ignoreTls: false, upsideDown: false,
  maxredirects: 10, expiryNotification: false, packetSize: 56, invertKeyword: false, grpcEnableTls: false,
  kafkaProducerSsl: false, kafkaProducerAllowAutoTopicCreation: false, gamedigGivenPortOnly: true, cacheBust: false,
  mqttCheckType: "keyword", wsIgnoreSecWebsocketAcceptHeader: false, wsSubprotocol: "", pingCount: 1,
  pingNumeric: true, pingPerRequestTimeout: 2, saveResponse: false, saveErrorResponse: true, responseMaxLength: 1024,
  httpBodyEncoding: "json",
};
const H = "http://host.docker.internal";
const monitors = [
  { name: "Jellyfin", url: `${H}:8096/health` },
  { name: "Open WebUI", url: `${H}:3080/health` },
  { name: "MeTube", url: `${H}:8081/` },
  { name: "Ollama", url: `${H}:11434/api/version` },
  { name: "Dozzle", url: `${H}:8080/` },
  { name: "Internet (YouTube)", url: "https://www.youtube.com/", interval: 300, retryInterval: 120, description: "Is the home connection up" },
];
// Homepage rejects direct requests in its Host check (400), so go through Tailscale HTTPS - which also monitors
// tailscale serve and certificate expiry
if (TS_FQDN) monitors.unshift({ name: "Homepage (Tailscale HTTPS)", url: `https://${TS_FQDN}/`, expiryNotification: true });

const NTFY_NAME = "ntfy (chi)";
const MSG = {
  authIncorrectCreds: "Incorrect username or password",
  "Too frequently, try again later.": "Too many logins (Kuma allows 20 per minute), wait a minute and retry",
};
const tr = (m) => MSG[m] || m;

// Start listening before login: Kuma pushes monitorList / notificationList before the login callback
let monitorList = null;
let notificationList = null;
const s = io("http://127.0.0.1:3001", { transports: ["websocket"], reconnection: false, timeout: CALL_TIMEOUT });
s.on("monitorList", (l) => { monitorList = l; });
s.on("notificationList", (l) => { notificationList = l; });
s.on("connect_error", (e) => fail("Cannot connect to Kuma (127.0.0.1:3001): " + e.message));

const call = async (ev, ...args) => {
  try {
    return await s.timeout(CALL_TIMEOUT).emitWithAck(ev, ...args);
  } catch (e) {
    return fail(`${ev}: no reply within ${CALL_TIMEOUT / 1000}s (${e.message})`);
  }
};

say("Connecting to Kuma...");
s.on("connect", () => say("Connected, waiting for the server to be ready..."));
// In its connection handler Kuma awaits sendInfo (a DB query) before registering login and other handlers; a login
// sent before that is silently dropped and its callback never fires (why older versions hung). So log in after info.
s.once("info", async () => {
  say(`Logging in as ${KUMA_USER}...`);
  const login = await call("login", { username: KUMA_USER, password, token: "" });
  if (login.tokenRequired) fail("This account has two-factor auth (2FA) on, which the script does not support; add monitors in the web UI");
  if (!login.ok) fail("Login failed: " + tr(login.msg));
  const existing = new Set(Object.values(monitorList || {}).map((m) => m.name));
  say(`Logged in, ${existing.size} existing monitors`);

  // Optional: ntfy notification (upserted by name, so re-running after editing .env updates it)
  const notificationIDList = {};
  if (NTFY_TOPIC) {
    const server = (NTFY_SERVER || "https://ntfy.sh").replace(/\/+$/, "");
    const old = (notificationList || []).find((n) => n.name === NTFY_NAME);
    const res = await call("addNotification", {
      name: NTFY_NAME, type: "ntfy", isDefault: true, applyExisting: false, active: true,
      ntfyserverurl: server, ntfytopic: NTFY_TOPIC, ntfyPriority: 5, ntfyPriorityDown: 5,
      ntfyAuthenticationMethod: "none", ntfyUseTemplate: false,
    }, old ? old.id : null);
    if (res.ok) {
      notificationIDList[res.id] = true;
      console.log(` ✓ ntfy notification ${old ? "updated" : "created"}: ${server}/${NTFY_TOPIC} (set as default, attached to new monitors)`);
    } else {
      console.log(` ✗ ntfy notification: ${res.msg} (monitors are still added, without notification)`);
    }
  }

  let added = 0;
  for (const m of monitors) {
    if (existing.has(m.name)) { console.log(` - ${m.name}: exists, skipped`); continue; }
    const res = await call("add", { ...base, ...m, notificationIDList });
    if (res.ok) added++;
    console.log(res.ok ? ` ✓ ${m.name}` : ` ✗ ${m.name}: ${res.msg}`);
  }
  say(`Done: ${added} added`);
  s.close();
  process.exit(0);
});
JS

docker cp "$js_local" "chi-uptime-kuma:$js_remote" >/dev/null

printf '%s' "$pass" | docker exec -i \
  -e KUMA_USER="$user" -e TS_FQDN="${TS_FQDN:-}" -e NTFY_TOPIC="${NTFY_TOPIC:-}" -e NTFY_SERVER="${NTFY_SERVER:-}" \
  -w /app chi-uptime-kuma node "$js_remote"
