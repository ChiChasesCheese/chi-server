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
