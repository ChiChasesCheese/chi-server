# 远程访问

## 控制机：用 MacBook 管 mini（日常方式）

一次性准备（在 MacBook 上）：

1. 装 Tailscale 并用同一账号登录。`brew install --cask tailscale-app` 要 sudo，在 Claude Code 的 `!` 模式里会失败，改用 `brew fetch --cask tailscale-app` 后 `open` 下载好的 pkg，或直接 App Store。
2. 专用 SSH 密钥 + 配置（mini 上的用户名是 **chiserver**，不是 MacBook 的用户名）：
   ```sshconfig
   Host chi-mini
     HostName chi-mini
     User chiserver
     IdentityFile ~/.ssh/chi_mini_ed25519
     IdentitiesOnly yes
     ServerAliveInterval 30
   ```
   第一次连接要确认主机指纹；没有交互终端时可先 `ssh-keyscan -t ed25519 chi-mini >> ~/.ssh/known_hosts`（经 Tailscale 拿到的指纹可信）。公钥放进 mini 的 `~/.ssh/authorized_keys`。
3. 本仓库在 MacBook 上也 clone 一份，代码在这里改、commit、push，mini 上 `git pull`。

日常：

| 想做的事 | 命令（在 MacBook 上） |
|---|---|
| 进 mini | `ssh chi-mini` |
| 端到端体检（用户视角） | `bin/chi remote-check` |
| mini 上的体检 | `ssh chi-mini 'cd ~/chi-service && bin/chi doctor'` |
| 部署改动 | `git push` → `ssh chi-mini 'cd ~/chi-service && git pull && bin/chi up'` |
| 重启 | `ssh chi-mini 'sudo -n /sbin/shutdown -r now'`（需先配免密重启，见 macos-setup.md） |
| 看桌面 | `open vnc://chi-mini` |

## 默认：只在 tailnet 内（推荐，够用）

```
手机/笔记本 ── Tailscale ──► https://chi-mini.tailXXXX.ts.net[:端口]
```

- 每台要访问的设备装 Tailscale 客户端，登录同一个账号即可。
- 家人用：Tailscale 免费版支持多用户，邀请进你的 tailnet；或在管理后台用 **Share** 只分享这一台机器。
- SSH：`ssh 用户名@chi-mini`（MagicDNS 让短名可用）。
- 端口映射表：`scripts/tailscale-serve.sh` 的 `ports_for`。`chi serve status` 查看当前规则。

### 访问控制（ACL）

默认 tailnet 里所有设备互通。如果邀请了家人，建议在 Tailscale 管理后台 → Access Controls 限制他们只能访问特定端口，例如家人只能访问 Immich(8006) 和首页(443)：

```jsonc
{
  "grants": [
    { "src": ["autogroup:admin"], "dst": ["*"], "ip": ["*"] },
    { "src": ["group:family"], "dst": ["tag:server"], "ip": ["tcp:443", "tcp:8006"] }
  ]
}
```

（需要先给这台机器打上 `tag:server`。ACL 语法以 Tailscale 官方文档为准。）

## 想要漂亮的域名（photos.example.com）

两条路，都需要你有一个域名：

**方案 1：Caddy + DNS 验证 + 指向 Tailscale IP（仍然只有 tailnet 可访问）**
- DNS 里 `*.home.example.com` → A 记录指向这台机器的 Tailscale IP（100.x.y.z，公网解析到它也无害，外人连不上）。
- Caddy 用 Cloudflare DNS-01 申请通配符证书，按子域名反代到各个 127.0.0.1 端口。
- 需要带 `caddy-dns/cloudflare` 插件的 Caddy 镜像。这会多一个要维护的组件，所以没放进默认配置。

**方案 2：Cloudflare Tunnel（真正公网可访问）**
- 只用于**确实需要给外人/没装 Tailscale 的设备访问**的个别服务，比如 n8n 的 webhook 接收第三方回调。
- `brew install cloudflared` → `cloudflared tunnel login` → 创建隧道 → 配置单个 hostname → 用 `cloudflared service install` 装成系统服务。
- 必须在前面加 **Cloudflare Access**（邮箱验证码/OAuth）做认证，不要把任何管理界面裸露到公网。
- 不要用它跑 Immich 上传/视频流：Cloudflare 免费版有单请求 100 MB 上限，且条款不允许大流量视频。

**不要做的事**：路由器端口转发 22 / 5900 / 任何管理端口。

## Funnel？

`tailscale funnel` 能把 tailnet 内的服务公开到公网。对 n8n webhook 这种场景比 Cloudflare Tunnel 更省事（不用域名），但只能用 443/8443/10000 端口，且同样**没有认证层**——只对本身有认证、需要公网回调的服务用。
