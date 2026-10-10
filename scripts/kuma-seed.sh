#!/usr/bin/env bash
# 给 Uptime Kuma 添加一组默认监控（各服务健康检查 + 外网）。会提示输入 Kuma 账号密码，走正常登录。
# 用法：scripts/kuma-seed.sh [用户名]
# 幂等：同名监控已存在就跳过，重复跑不会重复添加。
# 可选：.env 里设了 NTFY_TOPIC（和可选的 NTFY_SERVER，默认 https://ntfy.sh），
#       会建一个 ntfy 通知（设为默认），并挂到这次新加的监控上。手机装 ntfy App 订阅同名 topic 即可收到。
#       注意：ntfy.sh 公共服务器上 topic 名就是“密码”，谁知道名字谁就能订阅，起个难猜的。
# 账号密码从 /dev/tty 读；JS 用 docker cp 传进容器，stdin 只用来传密码；每次调用 20s、整体 60s 超时。
set -euo pipefail
. "$(dirname "$0")/lib.sh"
load_env
ensure_brew_path
docker ps --format '{{.Names}}' | grep -qx chi-uptime-kuma || die "chi-uptime-kuma 没在跑 → chi up core"

{ : </dev/tty; } 2>/dev/null || die "需要在交互式终端里运行（读不到 /dev/tty）"
user="${1:-}"
[ -n "$user" ] || read -r -p "Uptime Kuma 用户名: " user </dev/tty
[ -n "$user" ] || die "用户名为空"
IFS= read -r -s -p "Uptime Kuma 密码: " pass </dev/tty; echo >&2
[ -n "$pass" ] || die "密码为空"

js_local="$(mktemp "${TMPDIR:-/tmp}/chi-kuma-seed.XXXXXX")"
js_remote="/tmp/chi-kuma-seed.$$.js"
# shellcheck disable=SC2329  # 由 trap 调用
cleanup() {
  rm -f "$js_local"
  # 只删我们自己拷进去的脚本文件；绝不在 Kuma 容器里杀进程（会连带杀掉内嵌的 MariaDB）
  docker exec chi-uptime-kuma rm -f "$js_remote" >/dev/null 2>&1 || true
}
trap cleanup EXIT

cat >"$js_local" <<'JS'
const { io } = require("/app/node_modules/socket.io-client");
const fs = require("fs");

const CALL_TIMEOUT = 20000; // 每次调用
const TOTAL_TIMEOUT = 60000; // 整体
const t0 = Date.now();
const say = (m) => console.log(`   [${((Date.now() - t0) / 1000).toFixed(1)}s] ${m}`);
const fail = (m) => { console.error(` ✗ ${m}`); process.exit(1); };
setTimeout(() => fail(`整体超时（${TOTAL_TIMEOUT / 1000}s）：Kuma 没响应。看 docker logs --tail 50 chi-uptime-kuma`), TOTAL_TIMEOUT).unref();

const password = fs.readFileSync(0, "utf8"); // 密码从 stdin 读（bash 那边 printf 过来，没有换行）
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
  { name: "外网（YouTube）", url: "https://www.youtube.com/", interval: 300, retryInterval: 120, description: "家里宽带是否通" },
];
// Homepage 直连会被它的 Host 校验拒绝（400），所以走 Tailscale HTTPS，顺带监控 tailscale serve 和证书到期
if (TS_FQDN) monitors.unshift({ name: "首页（Tailscale HTTPS）", url: `https://${TS_FQDN}/`, expiryNotification: true });

const NTFY_NAME = "ntfy（chi）";
const MSG = {
  authIncorrectCreds: "用户名或密码错误",
  "Too frequently, try again later.": "登录太频繁（Kuma 限制每分钟 20 次），等一分钟再试",
};
const tr = (m) => MSG[m] || m;

// 登录前就开始收：Kuma 在登录回调之前推送 monitorList / notificationList
let monitorList = null;
let notificationList = null;
const s = io("http://127.0.0.1:3001", { transports: ["websocket"], reconnection: false, timeout: CALL_TIMEOUT });
s.on("monitorList", (l) => { monitorList = l; });
s.on("notificationList", (l) => { notificationList = l; });
s.on("connect_error", (e) => fail("连不上 Kuma（127.0.0.1:3001）：" + e.message));

const call = async (ev, ...args) => {
  try {
    return await s.timeout(CALL_TIMEOUT).emitWithAck(ev, ...args);
  } catch (e) {
    return fail(`${ev} 调用 ${CALL_TIMEOUT / 1000}s 没有回应（${e.message}）`);
  }
};

say("连接 Kuma…");
s.on("connect", () => say("已连接，等服务端就绪…"));
// Kuma 在连接回调里先 await sendInfo（查库）才注册 login 等处理器，在那之前发的 login 会被静默丢掉、
// 回调永远不来（旧版卡死的根因）。所以等收到 info 再登录。
s.once("info", async () => {
  say(`登录 ${KUMA_USER}…`);
  const login = await call("login", { username: KUMA_USER, password, token: "" });
  if (login.tokenRequired) fail("这个账号开了两步验证（2FA），脚本不支持，先在网页里手动加");
  if (!login.ok) fail("登录失败：" + tr(login.msg));
  const existing = new Set(Object.values(monitorList || {}).map((m) => m.name));
  say(`登录成功，已有 ${existing.size} 个监控`);

  // 可选：ntfy 通知（按名字 upsert，改了 .env 再跑会更新）
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
      console.log(` ✓ ntfy 通知${old ? "已更新" : "已创建"}：${server}/${NTFY_TOPIC}（设为默认，挂到新加的监控）`);
    } else {
      console.log(` ✗ ntfy 通知：${res.msg}（监控照常添加，不挂通知）`);
    }
  }

  let added = 0;
  for (const m of monitors) {
    if (existing.has(m.name)) { console.log(` - ${m.name}：已存在，跳过`); continue; }
    const res = await call("add", { ...base, ...m, notificationIDList });
    if (res.ok) added++;
    console.log(res.ok ? ` ✓ ${m.name}` : ` ✗ ${m.name}：${res.msg}`);
  }
  say(`完成：新加 ${added} 个`);
  s.close();
  process.exit(0);
});
JS

docker cp "$js_local" "chi-uptime-kuma:$js_remote" >/dev/null

printf '%s' "$pass" | docker exec -i \
  -e KUMA_USER="$user" -e TS_FQDN="${TS_FQDN:-}" -e NTFY_TOPIC="${NTFY_TOPIC:-}" -e NTFY_SERVER="${NTFY_SERVER:-}" \
  -w /app chi-uptime-kuma node "$js_remote"
