# 架构与选型：为什么这么搭

每个决定写清楚：选了什么、放弃了什么、什么情况下应该换。不同意哪条就改哪条，脚本都是解耦的。

## 总原则

1. **Git 是唯一事实来源**。所有服务定义、系统设置都在仓库里，可以 review、可以回滚。不用 Portainer / Dockge 这类网页面板来改配置——它们方便，但会让“机器上的实际状态”和“仓库里写的”慢慢不一致（配置漂移）。网页上只**看**（Homepage、Dozzle），改都走 Git。
2. **代码、数据、秘密三分离**。仓库 = 代码；`DATA_DIR` = 数据；`.env` = 秘密。备份只需要后两者。
3. **零公网端口**。所有访问走 Tailscale。家用服务器被打穿的主要原因就是端口转发 + 弱密码/未修补漏洞。
4. **能原生就原生，要隔离就容器**。macOS 上的容器是虚拟机里的二等公民，需要硬件加速的东西必须原生。
5. **不做自动升级**。手动 `chi update`，你知道什么时候变了什么。
6. **一个入口**。`bin/chi` 读一遍就知道整个系统能干什么。

## 容器运行时：OrbStack（默认）/ Colima

| | OrbStack | Colima | Docker Desktop | Apple `container` |
|---|---|---|---|---|
| 开源 | ✗ | ✓ | ✗ | ✓ |
| 个人使用 | 免费 | 免费 | 免费 | 免费 |
| 商用 | $8/人/月 | 免费 | 大公司收费 | 免费 |
| 资源占用 | 最低，动态释放内存 | 低，内存固定分配 | 高 | 低 |
| docker compose | ✓ | ✓ | ✓ | ✗（只有第三方 apple-compose） |
| 稳定性 / 生态 | 好 | 好 | 好 | 2026-06 才 1.0 |

- **选 OrbStack**：家用属于个人使用免费；内存按需分配（Colima 的 VM 是固定内存，给 8 GB 就占 8 GB），这在要和大模型抢统一内存的 Mac mini 上很重要；bind mount 文件权限处理得最好。
- **什么时候换 Colima**：介意闭源，或者这台机器用于商业用途。`.env` 改 `CHI_RUNTIME=colima` 后 `chi bootstrap runtime`。
- **Apple `container`**：方向是对的（每个容器一个轻量 VM，隔离更强），但没有原生 compose，生态还不成熟。一两年后再评估。

## 远程访问：Tailscale + `tailscale serve`

- **为什么不是端口转发 / DDNS**：暴露攻击面，还要自己管证书。
- **为什么不是 Cloudflare Tunnel 作为主入口**：它是给“公开给别人访问”用的，流量过 Cloudflare 解密（TLS 在他们那终止），而且大文件（Immich 上传视频）有限制。Tailscale 是点对点 WireGuard，Tailscale 公司看不到内容。
- **为什么用 brew 的开源 `tailscaled` 而不是 App Store 版**：App Store 版是登录后才启动的；开源版装成 **LaunchDaemon，开机即上线**，没人登录也能 SSH 进来。服务器需要后者。
- **为什么用 `tailscale serve` 而不是 Caddy 反代**：零配置自动 HTTPS，不需要域名。代价是 URL 带端口号。想要 `photos.example.com` 这种漂亮域名，见 [remote-access.md](remote-access.md)。
- 端口统一绑在 `127.0.0.1`，只有 `tailscale serve` 能转进来；局域网里没装 Tailscale 的家人要用，把 `BIND_ADDR` 改成 `0.0.0.0`。

## 为什么 Ollama 不进容器

macOS 上 Docker 容器在 Linux 虚拟机里，**拿不到 Metal GPU**。同一个模型，原生 Ollama（Metal）通常比容器里（纯 CPU）快好几倍，具体倍数看模型和芯片。所以 Ollama 用 brew 装在宿主机，Open WebUI（纯 Web 应用）进容器，通过 `host.docker.internal:11434` 连过去。同理，Immich 的机器学习（人脸/语义搜索）在容器里只能用 CPU——能用，首次导入慢，这是已知取舍。

## 备份：restic

- **为什么 restic**：增量 + 去重 + 默认加密，后端支持本地盘 / B2 / S3 / R2 / SFTP，单个二进制，十年老项目。备选 Borg（需要服务端也装 borg）、Kopia（也不错，GUI 更好）。
- **一致性**：SQLite 类应用（Uptime Kuma、Vaultwarden、n8n、Open WebUI）在写入中途复制会得到损坏的数据库。脚本的做法是**短暂停容器→快照→启动**，增量备份一般几十秒。Postgres（Immich）用 `pg_dumpall` 在线导出，这是 Immich 官方推荐做法。
- **3-2-1 原则**：3 份数据，2 种介质，1 份异地。建议：本机 + Time Machine 外置盘（整机）+ restic 到 B2/R2（服务数据，异地）。
- **Time Machine 和 restic 不重复**：前者恢复整台 macOS，后者是可以在**任何机器**上恢复的服务数据。

## 定时任务：launchd，不是 cron

cron 在 macOS 上是遗留组件：睡眠时错过的任务不补跑，权限（TCC）管理更混乱。launchd 是 Apple 的正路，`launchctl kickstart` 可以手动触发、日志路径明确。

## 为什么不用 Watchtower

`containrrr/watchtower` 已于 2025 年 12 月归档。更重要的是**无人值守自动升级在家用场景弊大于利**：某天半夜一个破坏性变更让服务挂了，你一周后才发现。手动 `chi update` + 读 release notes 是更好的习惯。想要“有更新时通知我”，可以加 What's Up Docker（WUD），只通知不升级。

## 脚本风格

- 全部 bash 3.2 兼容（macOS 自带版本），不依赖 brew 的新 bash 就能跑 bootstrap。
- 全部幂等：任何一步可以重复跑。
- `set -euo pipefail`，失败就停，不静默继续。
- CI 跑 `shellcheck` 和 `docker compose config`。

## 参考过的开源项目 / 资料

- [smartwatermelon/mac-server-setup](https://github.com/smartwatermelon/mac-server-setup) — Mac mini 服务器自动化：分阶段装机、pmset、launchd、幂等脚本。本仓库的 `macos.sh` 思路主要参考它，但简化了（它更偏媒体服务器 + 1Password 凭据下发）。
- [gethomepage/homepage](https://github.com/gethomepage/homepage)、[louislam/uptime-kuma](https://github.com/louislam/uptime-kuma)、[amir20/dozzle](https://github.com/amir20/dozzle)
- [immich-app/immich](https://github.com/immich-app/immich) — 官方 compose + 备份文档
- [restic/restic](https://github.com/restic/restic)
- Tailscale 文档：`tailscale serve`、macOS 开源 `tailscaled` 变体
- macOS 26 FileVault 预启动 SSH 解锁的社区实测文章（[deepakness](https://deepakness.com/raw/remote-filevault-unlock-macos-tahoe/)、[Michael Tsai 汇总](https://mjtsai.com/blog/2025/09/22/tahoe-filevault-icloud-keychain-and-ssh/)）
- OrbStack 授权说明：<https://docs.orbstack.dev/licensing>
