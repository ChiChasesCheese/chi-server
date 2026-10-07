# 日常运维

## 节奏

| 频率 | 做什么 |
|---|---|
| 自动·每天 | `chi backup run`（launchd，`chi schedule` 安装） |
| 每 1–2 周 | `chi update` → `chi doctor` |
| 每月 | `chi backup check`（抽查 5% 数据可读）；看一眼 `chi backup snapshots` |
| 每季度 | **恢复演练**（见下） |
| macOS 更新 | 按 [macos-setup.md §4](macos-setup.md#4-系统升级怎么做) |

## 改配置

```bash
cd ~/chi-service
git pull                       # 在别处改了仓库的话
bin/chi init                   # 新版 .env.example 有新键就补上
bin/chi up                     # compose 只会重建有变化的容器
bin/chi serve                  # 改了端口才需要
```

在本机改了东西记得 commit + push，让仓库保持是真实状态。

## 备份与恢复

```bash
chi backup init         # 一次性
chi backup run          # 手动跑一次
chi backup snapshots    # 列快照
chi backup check        # 校验
```

备份内容：`$DATA_DIR`（除 Immich 的 postgres 原始目录）、Immich 数据库 SQL 导出、`.env`。
**不在备份里**：restic 密码本身（它在 `~/.config/chi/restic-password`，你必须另存到密码管理器——而且最好别只存在你自托管的 Vaultwarden 里，鸡生蛋问题）；Ollama 模型（可重新下载）。

### 恢复演练（新机器 / 机器挂了也是这个流程）

```bash
# 1. 新 Mac 上
git clone https://github.com/chichasescheese/chi-service.git ~/chi-service && cd ~/chi-service
mkdir -p ~/.config/chi && pbpaste > ~/.config/chi/restic-password   # 从密码管理器粘贴
export RESTIC_REPOSITORY=<你的仓库> RESTIC_PASSWORD_FILE=~/.config/chi/restic-password
# （B2/S3 还要 export 对应的 key）

# 2. 恢复 .env 和数据（恢复到原路径；路径不同的话之后改 .env 里的 DATA_DIR）
restic snapshots
restic restore latest --tag config --target /
restic restore latest --tag apps   --target /
restic restore latest --tag photos --target /     # 如果有

# 3. 装机并启动
bin/chi bootstrap
bin/chi up            # 除 photos 外数据已就位

# 4. Immich 数据库：先只起数据库，导入 SQL，再全部起来
#    按 Immich 官方文档 "Backup and Restore" 一节的命令操作（版本间有差异，以官方为准）
```

演练时恢复到一个临时目录（`--target /tmp/restore-test`），确认文件都在、SQLite 能打开就行，不用真的覆盖生产。

## 排障

| 症状 | 先看 |
|---|---|
| 所有服务都打不开 | `chi doctor`；`tailscale status`；OrbStack 是否在运行（重启后没人登录？） |
| 某个服务打不开 | `chi ps <stack>`；`chi logs <stack>` |
| 重启后服务没回来 | 是否自动登录了？OrbStack 是否开机自启？见 [macos-setup.md](macos-setup.md) FileVault 一节 |
| `chi serve` 报证书错误 | Tailscale 后台是否开了 HTTPS Certificates；`TS_FQDN` 是否正确 |
| 容器写数据权限错误（Colima） | `chmod -R u+rwX,g+rwX $DATA_DIR/<服务>`；或改用 OrbStack |
| 备份在 launchd 里失败、手动跑正常 | 看 `~/Library/Logs/chi-service/backup.log`。备份到外置盘时 macOS 可能弹“访问可移除宗卷”权限——需要给 `/bin/bash` 和 `restic`（`/opt/homebrew/bin/restic`）加“完全磁盘访问权限” |
| Ollama 很慢 | `ollama ps` 看是否 100% GPU；模型太大会部分落到 CPU，换小一号的 |
| 磁盘满 | `docker system df`；`docker image prune -a`；OrbStack 的 VM 磁盘会自动回收空间 |

宿主机真实负载：`ssh chi-mini` 后 `btop`（Homepage 上的 CPU/内存是容器 VM 的）。

## 加一个新服务

1. 新建 `stacks/<name>/compose.yaml`，参照现有的：`container_name: chi-<svc>`、`restart: unless-stopped`、端口绑 `${BIND_ADDR:-127.0.0.1}`、数据放 `${DATA_DIR}/<svc>`。
2. `scripts/tailscale-serve.sh` 的 `ports_for` 里加一行。
3. `stacks/core/homepage/services.yaml` 加卡片。
4. 有 SQLite 等数据库的，确认 `backup.sh` 的停机策略覆盖到（默认覆盖所有启用的 stack）。
5. `.env` 的 `CHI_STACKS` 加上名字 → `chi up <name>` → `chi serve`。
