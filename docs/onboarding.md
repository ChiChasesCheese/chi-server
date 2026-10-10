# 接入与分享：你自己的 iPhone / MacBook，以及朋友

## 朋友看到的是什么

`chi onboard` 会生成一个**接入页面**，放在 `https://<TS_FQDN>:8008`（只有 tailnet 能打开），里面已经填好了你服务器的真实地址，包括：
- iPhone / MacBook / Android 怎么装 Tailscale、怎么连
- Jellyfin（Swiftfin）怎么登录
- 怎么用 PAC 看 B 站大陆内容
- iPhone 快捷指令：分享菜单一键发给服务器下载
- 使用约定和排障

同时它会在终端打印一段**可以直接发微信/iMessage 的邀请文字**。朋友装好 Tailscale、点开你的分享链接，然后打开这个页面照着做就行。你自己的 iPhone 和 MacBook 也照同一个页面配。

## 你（管理员）第一次要做的

1. `bin/chi onboard` → 生成页面，并通过 `chi serve` 发布到 :8008
2. **ACL：限制朋友能访问的端口**。Tailscale 管理后台 → Access Controls，在策略里加上（保留你自己的全权限）：

```jsonc
{
  "grants": [
    // 你自己 tailnet 里的成员（你本人的设备）：全部
    { "src": ["autogroup:member"], "dst": ["*"], "ip": ["*"] },
    // 被分享了这台机器的朋友：只开这些端口
    //   443 首页 · 8008 接入页面/PAC · 8009 Jellyfin · 7890 回国代理
    //   想让朋友也能用 MeTube 下载，就加 "tcp:8010"；AI 聊天加 "tcp:8003"
    { "src": ["autogroup:shared"], "dst": ["*"], "ip": ["tcp:443", "tcp:8008", "tcp:8009", "tcp:7890"] }
  ]
}
```

   按 Tailscale 文档，分享出去的用户本来就**只能看到你分享的那台机器**；这条规则再把端口收窄。SSH、Uptime Kuma、Dozzle、mihomo 面板、Vaultwarden 对朋友都不可达。（语法以 Tailscale 官方 grants 文档为准，保存时后台会校验。）

   不想手改也可以用脚本：策略还是默认的 allow-all 时，`scripts/friend-ts.sh allow` 会提议换成上面这份（见下一节）。

### 用脚本做（Tailscale API）：`scripts/friend-ts.sh`

`tailscale` 命令行改不了策略、也建不了分享，这个脚本走 Tailscale API v2。先建令牌（只做一次，最长 90 天过期，过期了重建覆盖即可）：
Tailscale 后台 → Settings → Keys → **Generate access token**，复制后：

```bash
(umask 077 && mkdir -p ~/.config/chi && pbpaste > ~/.config/chi/tailscale-api-key)   # SSH 里用 cat > 再粘贴，Ctrl-D
```

```bash
scripts/friend-ts.sh invite [他的邮箱]     # 生成单次分享链接（给邮箱就由 Tailscale 发信，但谁点都能接受）
scripts/friend-ts.sh status                # 设备 / 邀请（看他接受时的登录名 acceptedBy）/ 朋友规则
scripts/friend-ts.sh allow 他的登录名       # 放行屏幕共享 tcp:5900 + udp:5900-5902；后面可追加端口，如 8010
scripts/friend-ts.sh revoke 他的登录名      # 删掉他的额外端口（分享本身要在后台 Share… → Revoke）
scripts/friend-ts.sh cleanup               # 删除离线的 chi-mini-* 旧节点（如卸载 Tailscale.app 留下的 chi-mini-1）
```

`allow`/`revoke` 会先把当前策略原文备份到 `~/.config/chi/acl-backups/`，调用 API 校验（顺带测你自己仍能连本机），显示 diff，你确认后才带 If-Match 写入。注意：API 用 JSON 写回，后台策略里的 `//` 注释会丢，要找回看备份。规则里的邮箱必须是朋友**接受邀请时的 Tailscale 登录名**（GitHub 登录的形如 `name@github`），不是你发邀请填的邮箱。

## 每邀请一个朋友

1. Tailscale 后台 → Machines → 你的 Mac mini → `…` → **Share…** → 复制邀请链接（每个人单独一个）
2. Jellyfin → 控制台 → 用户 → 新建账号（可以只给部分媒体库、关掉删除权限）
3. 把 `chi onboard` 打印的邀请文字 + 链接 + Jellyfin 账号发给他
4. 想收回：Tailscale 后台撤销分享；Jellyfin 禁用账号

为什么用“分享机器”而不是把朋友拉进你的 tailnet：分享只暴露这一台机器，朋友用他自己的 Tailscale 账号，你家里其他设备对他不可见，撤销也是一键。

## 各设备的能力边界（说实话）

| | 看 Jellyfin | 用服务 | 看 B 站大陆内容 |
|---|---|---|---|
| MacBook | ✓ 浏览器 / 客户端 | ✓ | ✓ **在哪都行**（系统代理设 PAC，Tailscale 开着） |
| iPhone 在家 Wi‑Fi | ✓ Swiftfin | ✓ | ✓（Wi‑Fi 代理设 PAC）；同时开着 Tailscale 时个别 App 可能不遵守，需实测 |
| iPhone 蜂窝网络 | ✓ | ✓ | ✗ iOS 不支持给蜂窝网络设代理，且同时只能开一个 VPN 类 App |
| onn 盒子 | ✓ 局域网直连 | — | ✓（`chi tv proxy`） |
| 朋友（异地） | ✓ | 按 ACL | Mac ✓；iPhone 只在他自己 Wi‑Fi 上、开着 Tailscale 时可试 |

朋友用回国代理，流量走的是你家宽带 + 你的回国 VPN 流量包。不想给朋友用，从 ACL 里去掉 `tcp:7890` 即可。

## 页面要更新时

改了端口、换了机器名、调了 `MEDIA_MAX_GB` 之后：`bin/chi onboard` 重新生成即可，链接不变。

## 朋友远程使用这台 Mac（屏幕共享，各用各的账号）

macOS 自带的「屏幕共享」支持**另一个用户用自己的账号登录一个独立的后台会话**：你在用着这台 Mac，朋友连进来选「以自己身份登录」，他看到的是他自己的桌面，你这边不受影响，也看不到对方。

**你（管理员）只做一次**（用你自己的账号跑，不要加 sudo，中途会要你的密码，还会让你给朋友设登录密码）：

```bash
scripts/friend-mac.sh add friend chimydad      # 朋友还要 SSH 的话末尾加 --ssh
scripts/friend-mac.sh status                   # 随时看现状，不需要 root
scripts/friend-mac.sh remove friend            # 收回（--delete 连账号和他的文件一起删）
```

它会：建标准（非管理员）账号或给已有账号补密码；把你和他的家目录改成 700；屏幕共享和 SSH 都改成「仅这些用户」（SSH 默认只留管理员）；关掉「VNC 用户可以使用密码控制屏幕」；打开屏幕共享。命令行开屏幕共享不是 Apple 官方支持的做法（macOS 12.1 起 kickstart 已经不行），没成功就手动：**系统设置 → 通用 → 共享 → 屏幕共享** 打开 → 点 (i) → VNC 密码**关**、允许访问选**仅这些用户**。跑完到这里核对一眼。

Tailscale 那边要给朋友放行 TCP 5900（用高性能模式还要 UDP 5900–5902）：`scripts/friend-ts.sh allow 他的登录名` 默认就是这两项，不含 SSH。

**朋友怎么连**（他的 Mac 上先连好 Tailscale）：

1. 打开「屏幕共享」App（或 Finder → 前往 → 连接服务器）→ 输入 `vnc://chi-mini.taila09b36.ts.net`
2. 用户名填他自己的账号名（如 `friend`）和密码
3. 提示这台 Mac 有人在用时，选 **以自己身份登录**（不要选共享屏幕，那是请求控制你的桌面）
4. 不用时 **注销**（苹果菜单 → 退出登录），只关窗口的话他的会话会一直挂着占内存

客户端：要用 Mac 自带的「屏幕共享」App。多用户独立会话是 Apple 对 VNC 的私有扩展，Windows 上的 RealVNC / TigerVNC 之类通常只能看到登录窗口或现有屏幕，不保证能开独立会话；iPad 上可以试 Screens 5（它支持“以自己身份登录”）。「高性能」模式要求两边都是 Apple 芯片 + macOS 14 以上，一台 Mac 同一时间只允许一个高性能连接，网速也要很好；隔着 Tailscale 远程一般用「标准」就行。

**朋友在他的会话里**：可以登录自己的 Apple 账户（iCloud、App Store 都行），但 **不要打开「查找我的 Mac」** —— 打开后这台 Mac 会被挂上他的激活锁，以后重装/抹掉都要他的 Apple 账户。系统设置 → [他的名字] → iCloud → 查找 里确认是关的。

**隐私，说实话**：

- 家目录 700 后，他看不到你的文件，你也看不到他的；但管理员（你）用 sudo 技术上能看他的一切，他要知道这一点。
- 他人就在这台机器上，所有监听在 `127.0.0.1` 和本机 Tailscale IP 上的端口对他都可达（Dozzle、Ollama 11434、Uptime Kuma、各服务管理页等）——Tailscale ACL 管的是网络进来的流量，管不到本机内部。有登录页的服务要设好密码，没密码的（如 Ollama、Dozzle）就当他能用。Docker（OrbStack）的 socket 实际在你的家目录里，家目录 700 后他碰不到。
- `/Users/Shared` 是所有本机用户都能读写的，别往里放私人东西。

**内存**：这台只有 16 GB，服务本身已经占了不少。多一个登录会话大约多吃 2–4 GB（开浏览器更多），内存紧张时 Ollama 之类会先变慢。`scripts/friend-mac.sh status` 能看到当前有几个会话和空闲内存。
