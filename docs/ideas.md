# 还能拿它干什么（按我认为的价值排序）

默认配置是“最小但完整”的骨架。下面是值得加的东西，以及**为什么没默认加**。

## 1. 外部心跳（强烈建议，10 分钟）

Uptime Kuma 和被监控的服务在同一台机器上，机器整个挂了（断电、断网）没人告诉你。
在 healthchecks.io（免费）建一个检查 → 在 n8n 里建一个每 5 分钟的定时工作流去 ping 它。机器挂了它就发邮件/推送。

## 2. AI 中枢

Mac mini 最独特的价值。

- **Claude Code / 编程 agent 常驻机**：在这台机器上装 Claude Code，通过 SSH（Tailscale）随时连上去跑长任务，笔记本合盖也不中断。用 `tmux` 保持会话。
- **OpenClaw 这类全天候个人 agent**：2026 年很多人买 Mac mini 就是为了它（能接 iMessage/WhatsApp、读邮件、执行任务）。**但请认真对待安全**：它需要很高的系统权限，已公开过多个认证类漏洞。如果要跑：
  - 用一个**单独的 macOS 标准用户**跑它，不要用你的管理员账户
  - 只给它最小的账户/API 权限，别连你的主邮箱
  - 管理界面绝不暴露到公网
  - 跟进每一个安全更新
- **本地 RAG**：Open WebUI 自带知识库功能，把文档扔进去，用本地模型问答，数据不出门。
- **语音转写**：`brew install whisper-cpp`（原生，Metal 加速），配合 n8n 处理录音。

## 3. Home Assistant（智能家居中枢）

没默认加，因为在 macOS 上**跑在 Docker 里是残废的**：Docker for Mac 没有真正的 host 网络，mDNS/SSDP 设备发现不工作，USB（Zigbee/Thread 棒）也没法直通。

正确做法：`brew install --cask utm` → 下载 Home Assistant OS 的 aarch64 镜像 → UTM 里建 VM，网络选**桥接**（让 VM 拿到局域网 IP）。USB 设备可以在 UTM 里直通给 VM。

## 4. 媒体库：Jellyfin / Plex

已做成 `media` stack（容器版 Jellyfin + MeTube），见 [media.md](media.md)，里面解释了为什么最终选了容器而不是原生。

## 5. 全家去广告 DNS：AdGuard Home

可以跑在这台机器上，然后在 Tailscale 后台把它设为 tailnet 的 DNS（所有设备在外面也去广告），或在路由器上设为局域网 DNS。
注意：如果把它设为整个家里的 DNS，这台 Mac 一挂全家断网。建议路由器上配一个备用 DNS。容器版在 Mac 上看不到真实客户端 IP（都是 VM 网关地址），所以建议原生跑或者只在 tailnet 用。

## 6. Time Machine 服务器

系统设置 → 通用 → 共享 → 文件共享 → 加一个外置盘上的文件夹 → 右键“高级选项”→ 勾选“作为 Time Machine 备份目的位置共享”。家里其他 Mac 就能备份到它上面。零额外软件。

## 7. 其他常见自托管服务

| 服务 | 干嘛的 | 备注 |
|---|---|---|
| Paperless-ngx | 纸质文档扫描归档 + OCR 全文搜索 | 有 Postgres，备份要加 dump |
| Syncthing | 设备间文件同步（不经过云） | `brew install syncthing`，原生 |
| Beszel | 轻量监控仪表盘 | agent 用原生安装才能看到宿主机真实指标 |
| What's Up Docker (WUD) | 镜像有更新时通知你（不自动升级） | 替代已归档的 Watchtower |
| Gitea / Forgejo | 自托管 Git | 你已有 GitHub，价值不大 |

## 我会怎么排优先级

第一周：core + vault + 外部心跳 + 备份 + 一次恢复演练。
第二周：ai，挑一个适合内存的模型，用 n8n 做一个每天早上的摘要推送。
之后：按真实需求加。**每加一个服务就多一份运维负担**——别因为“能装”就装。
