# chi-service

把一台 Mac mini 变成家里的 **always-on 服务器 / 中枢**：一条命令装机，一条命令起服务，配置全在 Git 里，坏了能从备份恢复。

```
                         你的手机 / 笔记本（装 Tailscale，在哪都能连）
                                       │  WireGuard 加密，不开任何公网端口
                                       ▼
┌──────────────────────────── Mac mini (macOS) ─────────────────────────────┐
│  tailscaled（系统守护进程，开机即上线）── tailscale serve ── HTTPS 证书自动签 │
│        │                                                                    │
│        ├─ :443  Homepage 首页 ──────┐                                        │
│        ├─ :8001 Uptime Kuma 监控    │                                        │
│        ├─ :8002 Dozzle 日志         │  OrbStack / Colima（Linux 轻量虚拟机）   │
│        ├─ :8003 Open WebUI ─────────┤  docker compose，按 stack 分组          │
│        ├─ :8004 n8n 自动化          │  数据全在 ~/srv/data                    │
│        ├─ :8005 Vaultwarden 密码    │                                        │
│        └─ :8006 Immich 相册 ────────┘                                        │
│                     │                                                       │
│        Ollama（原生，用 Metal GPU）◄── host.docker.internal:11434             │
│                                                                             │
│  launchd 每天 4:17 ── restic ──► 外置盘 / Backblaze B2 / S3（加密、增量）      │
└─────────────────────────────────────────────────────────────────────────────┘
```

## 先说实话：Mac mini 当服务器的优点和坑

**优点**：待机 5W 左右、几乎无声；Apple Silicon 的统一内存让它是**同价位跑本地大模型最好的机器**；macOS 稳定，能顺便当 Time Machine 服务器、iMessage 网关。

**坑**（这个仓库的设计都是围绕它们的）：

| 坑 | 后果 | 本仓库的处理 |
|---|---|---|
| Docker 在 macOS 上跑在 Linux 虚拟机里 | 容器**用不了 GPU / 神经网络引擎**；容器里看到的 CPU/内存是 VM 的 | 吃 GPU 的（Ollama）原生跑；其余进容器 |
| Docker 运行时是“登录后才启动”的用户级 App | 重启后**没人登录 = 服务全挂** | 自动登录 or FileVault 远程解锁，二选一，见 [macos-setup](docs/macos-setup.md) |
| FileVault 开着时重启卡在解锁界面 | 断电恢复后服务不会自己回来 | macOS 26 支持 SSH 预启动解锁（仅限局域网），详见文档 |
| macOS 自带 bash 3.2 | 现代 bash 写法会报错 | 脚本全部按 3.2 写，CI 跑 shellcheck |
| Docker Desktop 重、商用收费 | 浪费内存 | 默认 OrbStack（个人免费），可切 Colima（纯开源） |

如果你只想跑 Linux 容器、不在乎本地大模型，一台二手 N100 小主机装 Debian 会更“正统”。Mac mini 的价值在 **AI + 低功耗 + Apple 生态**，这套配置就是冲着这个设计的。

## 快速开始

在 Mac mini 上（先完成 [docs/macos-setup.md](docs/macos-setup.md) 里“装机前”那几步）：

```bash
git clone https://github.com/chichasescheese/chi-service.git ~/chi-service
cd ~/chi-service

bin/chi init            # 生成 .env（随机密钥、时区、路径），然后打开 .env 看一遍
bin/chi bootstrap       # Homebrew → 系统设置 → OrbStack → Tailscale → Ollama（会要 sudo）
bin/chi init            # Tailscale 登录后再跑一次，自动填 TS_FQDN
bin/chi up              # 启动 .env 里 CHI_STACKS 列出的服务
bin/chi serve           # 通过 Tailscale 以 HTTPS 暴露
bin/chi backup init     # 初始化备份仓库（先接好外置盘或填好 B2）
bin/chi schedule        # 每天自动备份
bin/chi doctor          # 体检，全绿就完事
```

然后在任何装了 Tailscale 的设备上打开 `https://<你的机器>.<tailnet>.ts.net`。

> 建议加个 alias：`echo 'alias chi=~/chi-service/bin/chi' >> ~/.zshrc`

## 命令速查

| 命令 | 作用 |
|---|---|
| `chi up / down / restart / ps [stack…]` | 起停服务；不写 stack = 全部启用的 |
| `chi logs <stack> [service]` | 跟日志 |
| `chi update [--no-brew]` | 升级 brew 包 + 镜像（手动跑，每 1–2 周一次） |
| `chi serve [apply\|status\|reset]` | Tailscale HTTPS 暴露 |
| `chi backup [init\|run\|snapshots\|check]` | restic 备份 |
| `chi schedule [install\|uninstall]` | launchd 定时备份 |
| `chi doctor` | 只读体检 |
| `chi proxy [install\|apply\|test\|status]` | 回国分流：只有大陆视频站走你的回国 VPN（[china-media](docs/china-media.md)） |
| `chi tv [connect\|install\|proxy]` | adb 远程管理 Google TV 盒子：侧载 App、设代理 |

## Stacks（在 `.env` 的 `CHI_STACKS` 里开关）

| stack | 内容 | 内存占用（大约） | 建议 |
|---|---|---|---|
| `core` | Homepage、Uptime Kuma、Dozzle | ~300 MB | 必开 |
| `ai` | Open WebUI（+ 宿主机 Ollama） | 1 GB + 模型大小 | 16 GB 起有意义 |
| `automation` | n8n | ~300 MB | “中枢”的核心 |
| `vault` | Vaultwarden | ~50 MB | 强烈推荐，前提是备份做好 |
| `photos` | Immich | 2–4 GB | 16 GB+ 再开 |

每个服务的用法、首次配置、内存怎么分配给模型，见 [docs/services.md](docs/services.md)。

## 目录结构

```
bin/chi                 唯一入口（读它就知道能干什么）
scripts/
  lib.sh                公共函数：日志、读 .env、统一的 compose 调用
  init-env.sh           生成/补全 .env
  bootstrap.sh          装机：brew / macos / runtime / tailscale / ollama
  macos.sh              系统设置（电源、防火墙、SSH、更新策略），每行都有注释
  tailscale-serve.sh    端口映射表在这里
  backup.sh             restic 备份策略
  update.sh             升级
  doctor.sh             体检
  schedule.sh           launchd 定时任务
  proxy.sh              mihomo 回国分流
  tv.sh                 adb 管理电视盒子
config/mihomo/          mihomo 配置模板（分流规则在这里改）
stacks/<name>/
  compose.yaml          这个 stack 的服务定义
  pre-up.sh             （可选）启动前钩子
  fetch.sh              （可选）从上游拉 compose（Immich 用）
launchd/                plist 模板
docs/                   所有“为什么”
Brewfile                宿主机工具
.env.example            全部配置项及说明
```

**原则**：仓库里只有“怎么跑”，没有数据和秘密。数据在 `DATA_DIR`（默认 `~/srv/data`），秘密在 `.env`（不进 git）。机器炸了 = 新机器 clone 仓库 + 从 restic 恢复 `DATA_DIR` 和 `.env`。

## 文档

1. [macos-setup.md](docs/macos-setup.md) — 装机清单，**必须手点的系统设置**，FileVault 怎么选
2. [architecture.md](docs/architecture.md) — 每个技术选型的理由、放弃了什么、参考了哪些开源项目
3. [remote-access.md](docs/remote-access.md) — Tailscale / 公网暴露 / 自己的域名
4. [services.md](docs/services.md) — 每个服务怎么用
5. [operations.md](docs/operations.md) — 日常运维、升级、**恢复演练**、排障
6. [china-media.md](docs/china-media.md) — 回国分流：在美国看 B 站等大陆限定内容，投影/电视盒子怎么配
7. [ideas.md](docs/ideas.md) — 还能拿它干什么（Home Assistant、AI agent、媒体库……）
