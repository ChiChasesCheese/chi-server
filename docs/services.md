# 服务说明

访问地址都是 `https://<TS_FQDN>:<端口>`（443 可省略）。端口表：

| 服务 | stack | 本机端口 | Tailscale HTTPS |
|---|---|---|---|
| Homepage | core | 3000 | 443 |
| Uptime Kuma | core | 3001 | 8001 |
| Dozzle | core | 8080 | 8002 |
| Open WebUI | ai | 3080 | 8003 |
| n8n | automation | 5678 | 8004 |
| Vaultwarden | vault | 8222 | 8005 |
| Immich | photos | 2283 | 8006 |
| Ollama（宿主机） | ai | 11434 | 不暴露 |

改端口要同步三处：`stacks/*/compose.yaml`、`scripts/tailscale-serve.sh`、`stacks/core/homepage/services.yaml`。

## 内存怎么分

Mac 的统一内存同时给 CPU、GPU（模型）和容器 VM 用。粗略预算：

| 机器内存 | 建议 | 本地模型尺寸 |
|---|---|---|
| 16 GB | core + automation + vault；ai 可开但只跑小模型；photos 慎开 | ≤ 8B 参数（Q4 量化约 5 GB） |
| 24 GB | 全开 | 8–14B |
| 32 GB | 全开，还有余量 | ~14–32B |
| 64 GB+ | 全开 | 32B–70B（70B Q4 约 40 GB） |

经验规则：模型文件大小 + 2–4 GB ≈ 它实际占用。macOS 默认只让 GPU 用约 2/3–3/4 的统一内存。

## core

**Homepage** — 首页。配置在 `stacks/core/homepage/*.yaml`，改完不用重启，刷新页面即可。容器状态通过只读 docker socket 获取。

**Uptime Kuma** — 第一次打开设管理员账号。建议加的监控：
- 每个服务的 HTTP 检查（用 `http://host.docker.internal:<本机端口>`）
- Ollama：`http://host.docker.internal:11434/api/version`
- 外网连通性：ping `1.1.1.1`
- 通知渠道：Telegram / Bark（iOS）/ ntfy / 邮件，在 Settings → Notifications 配。**没配通知的监控 = 没监控**。
- 说实话：Uptime Kuma 跑在被监控的同一台机器上，机器整个挂了它也挂了。补救：用免费的外部服务（如 healthchecks.io）配一个“心跳”——让 n8n 或 launchd 每 5 分钟 ping 一次，断了就由外部发告警。

**Dozzle** — 实时看所有容器日志，只读。

## ai

```bash
ollama pull <模型名>       # 在 https://ollama.com/library 挑，按上面的内存表选尺寸
ollama list
ollama ps                  # 看当前加载在内存里的模型
```

- Open WebUI 第一个注册的用户自动成为管理员；之后注册的需要管理员批准。
- 想让 n8n 调本地模型：n8n 里的 Ollama 节点填 `http://host.docker.internal:11434`。
- Ollama 默认只听 `127.0.0.1`，这是对的——它没有任何认证。**别把 11434 暴露到 tailnet/局域网**，要远程用就走 Open WebUI。
- 用 Colima 时容器可能访问不到宿主机的 127.0.0.1，这时需要让 Ollama 监听 `0.0.0.0`（`launchctl setenv OLLAMA_HOST 0.0.0.0` 后重启服务）并确认防火墙开着。OrbStack 不需要。

## automation（n8n）

“中枢”的核心。典型用法：
- 定时：每天早上汇总天气/日历/RSS → 调本地模型总结 → 推送到手机
- Webhook：接收 GitHub / 智能家居 / 快捷指令（iOS Shortcuts）的事件 → 分发
- 监控：每 5 分钟 ping healthchecks.io 做外部心跳

注意：
- `N8N_ENCRYPTION_KEY` 在 `.env` 里，它加密了 n8n 保存的所有凭据。**丢了它，所有凭据作废**。备份脚本会备份 `.env`。
- 需要接收**公网**回调的 webhook（第三方服务调你），见 [remote-access.md](remote-access.md) 的 Funnel / Cloudflare Tunnel。

## vault（Vaultwarden）

1. `.env`：`VAULTWARDEN_SIGNUPS_ALLOWED=true` → `chi up vault`
2. 打开 `https://<TS_FQDN>:8005` 注册你（和家人）的账号
3. 改回 `false` → `chi up vault`
4. 手机/浏览器装官方 Bitwarden 客户端，登录时选“自托管”，服务器填上面的地址

风险提示（说实话）：密码管理器自托管，**你就是运维**。备份没做好、机器挂了 = 所有密码没了。客户端有离线缓存能救急，但别依赖它。上线前至少做一次恢复演练（[operations.md](operations.md)）。

## photos（Immich）

- 第一次 `chi up photos` 会从 Immich 官方下载 compose 文件（不入库），生成 `stacks/photos/.env`（含随机数据库密码）。
- 打开 `https://<TS_FQDN>:8006` 创建管理员。手机装 Immich App，服务器填同一地址，开启后台备份。
- 照片在 `$DATA_DIR/immich/library`。如果照片库很大，建议把 `DATA_DIR`（或者只把 `immich/library`）放到外置 SSD 上，并在 `.env`/`stacks/photos/.env` 里改路径。外置盘要求：APFS 格式、开机自动挂载、**不要用 USB 机械盘放数据库**。
- 升级：Immich 有过破坏性变更。读 release notes → `stacks/photos/fetch.sh --force` → `chi up photos`。
- 已知限制：机器学习只能 CPU，几万张照片首次索引可能要跑一两天。之后增量很快。
