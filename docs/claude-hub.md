# 在这台 Mac 上跑 Claude 会话

笔记本合盖、手机在外面，任务照样在 Mac mini 上跑。命令以 Claude Code 官方文档为准（2026-10 核对；更新快，有出入以官方为准）。

| 方式 | 怎么开 | 从哪操作 | 断线 / 关窗口后 |
|---|---|---|---|
| **Claude Desktop（Code 标签页）** | 这台 Mac 的图形界面里开 Local 会话 | 屏幕共享进来；或会话里开 Remote Control 用手机 | 退出 App，Local 会话就离线 |
| **Remote Control** | SSH 进来，tmux 里跑 `claude remote-control` | 手机 Claude App、claude.ai/code | 进程在就行；服务器模式断网约 10 分钟会退出 |
| **tmux + ssh（mosh 可选）** | `ssh chi-mini` → `tmux` → `claude` | 任何终端 | tmux 里的进程不受断线影响 |
| **后台会话** | `claude --bg "<任务>"` | `claude agents` 看列表，`claude attach <id>` 接回 | 不需要终端；睡眠后恢复，**重启就停** |

## Remote Control（手机 / 网页遥控）

```bash
ssh chi-mini
tmux new -As rc
cd ~/Code/某项目
claude remote-control --name chi-mini --spawn worktree --capacity 4
# 或在已有会话里输入 /remote-control（/rc），只把这一个会话挂出去
```

- 要 Pro / Max / Team / Enterprise 订阅，`/login` 登录；API key 和 `claude setup-token` 的令牌都不行。
- 只走出站 HTTPS，不开入站端口，和 Tailscale ACL 无关；连着时会话记录存在 Anthropic 服务器上。
- `--spawn worktree`：每个会话各用一个 git worktree，不会几个会话改同一批文件；`--capacity` 默认 32，16 GB 的机器设小点。
- 服务器模式断网约 10 分钟就退出，家里宽带抖了要重开。懒得管就在 tmux 里套个循环：
  `while :; do claude remote-control --name chi-mini --spawn worktree --capacity 4; sleep 30; done`
- 第一次在某目录跑会问是否信任目录、是否启用 Remote Control，要在有终端的地方答一次。
- 来源：[Remote Control](https://code.claude.com/docs/en/remote-control)

## tmux + ssh

```bash
ssh chi-mini
tmux new -As main       # 有就接上，没有就新建；Ctrl-b d 脱离，下次同一条命令接回
claude
```

**mosh（可选，手机 / 高延迟 / 换网络不断线）**：

```bash
brew install mosh       # 服务器和你的 Mac 都装；iPhone 用 Blink Shell
mosh --server=/opt/homebrew/bin/mosh-server chiserver@chi-mini -- tmux new -As main
```

- mosh 先用 SSH 登录，再改走 **UDP 60000–61000**（[mosh.org](https://mosh.org/)）。你自己的设备在 Tailscale ACL 里本来就全放行，不用改。
- 非交互 SSH 的 PATH 里没有 `/opt/homebrew/bin`，所以要用 `--server=` 指路径。
- 这台机器 macOS 防火墙开着，卡在 “Connecting…” 就放行（brew 升级 mosh 后要重做）：
  `p="$(realpath /opt/homebrew/bin/mosh-server)"; sudo /usr/libexec/ApplicationFirewall/socketfilterfw --add "$p" --unblockapp "$p"`

## 后台会话

`claude --bg "修一下 xxx 测试"` 丢出去就不用管终端；`claude agents` 看所有后台会话，`claude attach <id>` 接回，`claude stop <id>` 停掉。空闲且没人看约一小时后进程会被收掉，对话还在，下次 attach 接着来。目前是 research preview。来源：[agent view](https://code.claude.com/docs/en/agent-view)

## 管理

- **SSH 里登录**：`/login` 时浏览器回调不到终端，会显示一个代码，粘到 `Paste code here if prompted` 即可。SSH 里钥匙串通常是锁着的，凭据会改存 `~/.claude/.credentials.json`（0600），正常。有问题先 `claude doctor`。来源：[authentication](https://code.claude.com/docs/en/authentication)
- **看在跑什么**：`tmux ls`、`claude agents`；手机 Claude App 里能看到 Remote Control 会话。
- **登录过期**：后台会话和 Remote Control 会话会停住，`/status` 看过期时间，重新 `/login`。
- **重启后**：tmux、Remote Control、后台会话都不会自己回来，要重新开（重启见 [macos-setup.md](macos-setup.md) FileVault 一节）。
- **别开太多**：16 GB 内存，每个活跃会话估计 0.3–0.6 GB（估算，本机实测 0.4–0.55 GB），同时活跃控制在 4 个左右；`memory_pressure | tail -1` 看空闲比例。
- **auto 模式**（`claude --permission-mode auto`）少弹确认，但官方原话 “does not guarantee safety”；没人看着时别让它碰 `.env` 和交易 key（[permission modes](https://code.claude.com/docs/en/permission-modes)）。
