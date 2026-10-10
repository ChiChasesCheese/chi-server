#!/usr/bin/env bash
# 给 Uptime Kuma 添加一组默认监控（各服务健康检查 + 外网）。会提示输入 Kuma 账号密码，走正常登录。
# 用法：scripts/kuma-seed.sh [用户名]     重复跑会重复添加，跑一次就够
set -euo pipefail
. "$(dirname "$0")/lib.sh"
load_env
docker ps --format '{{.Names}}' | grep -qx chi-uptime-kuma || die "chi-uptime-kuma 没在跑 → chi up core"
user="${1:-}"
[ -n "$user" ] || read -r -p "Uptime Kuma 用户名: " user
read -r -s -p "Uptime Kuma 密码: " pass; echo

docker exec -i -e KUMA_USER="$user" -e KUMA_PASS="$pass" -e TS_FQDN="${TS_FQDN:-}" -w /app chi-uptime-kuma node - <<'JS'
const { io } = require("/app/node_modules/socket.io-client");
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
  { name: "外网（YouTube）", url: "https://www.youtube.com/", interval: 300, retryInterval: 120, description: "家里宽带是否通" },
];
// Homepage 直连会被它的 Host 校验拒绝（400），所以走 Tailscale HTTPS，顺带监控 tailscale serve 和证书到期
if (process.env.TS_FQDN) monitors.unshift({ name: "首页（Tailscale HTTPS）", url: `https://${process.env.TS_FQDN}/`, expiryNotification: true });

const s = io("http://127.0.0.1:3001", { transports: ["websocket"] });
const emit = (ev, ...a) => new Promise((r) => s.emit(ev, ...a, r));
s.on("connect", async () => {
  const login = await emit("login", { username: process.env.KUMA_USER, password: process.env.KUMA_PASS, token: "" });
  if (!login.ok) { console.error(" ✗ 登录失败：" + login.msg); process.exit(1); }
  for (const m of monitors) {
    const res = await emit("add", { ...base, ...m });
    console.log(res.ok ? ` ✓ ${m.name}` : ` ✗ ${m.name}：${res.msg}`);
  }
  s.close();
});
s.on("connect_error", (e) => { console.error(" ✗ 连不上 Kuma：" + e.message); process.exit(1); });
JS
