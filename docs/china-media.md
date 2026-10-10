# 回国分流：在美国看 B 站 / 爱奇艺等大陆限定内容

## 原理

B 站等平台判断“你在不在大陆”看的是**请求它 API 的出口 IP**。所以只要让这些站点的流量从一个大陆节点出去就行，其他流量照常直连。

```
 Google TV 盒子 / 投影仪 / 手机
        │  系统 HTTP 代理 → Mac:7890
        ▼
 Mac mini 上的 mihomo（Clash Meta 内核）── 按域名分流 ──┐
        │                                              │
        │ bilibili / iqiyi / youku / v.qq.com / 网易云  │ 其他所有流量
        ▼                                              ▼
   你的回国 VPN 大陆节点（自动选最快）                   直连（Xfinity）
        ▼
   B 站看到的是「中国 上海」
```

为什么这么设计：
- **只分流，不全局**：VPN 商只看得到这几个站点的流量；回国节点又慢又贵，YouTube/Netflix 不该走它。
- **代理放在 Mac 上，不在每台设备上装**：订阅、规则、节点选择只维护一份，电视盒子只需要填一个代理地址。
- **mihomo 原生跑（brew），不进容器**：局域网设备要连它，原生最简单；brew 有正式包，`chi update` 会顺带升级。

## 1. 准备一个回国 VPN

你需要一个提供 **Clash / Clash Meta（mihomo）订阅链接** 的回国加速服务（海外华人常用的那类“回国 VPN/机场”）。我不推荐具体商家，挑的时候看：
- 有**大陆节点**，而且到美国的带宽够看 1080p（问客服或先买一个月试）
- 提供 Clash 订阅（几乎都有）
- 流量够用：1080p 大约 1–2 GB/小时，**视频本身也会走这个节点**（见下面“已知限制”）

说实话的风险：VPN 商能看到经过它的流量。本配置只让大陆视频站走它，**别把它当全局代理去登录银行/邮箱**。

## 2. 在 Mac mini 上安装

```bash
cd ~/chi-service
open -e .env
#   CLASH_SUBSCRIPTION_URL='https://你的订阅地址'     ← 一定用单引号
#   CLASH_CN_FILTER='...'   默认按“中国/回国/上海/CN…”挑节点；订阅里全是回国节点就写 '.*'
bin/chi init            # 生成 CLASH_SECRET
bin/chi proxy install   # 装 mihomo → 生成配置 → 启动 → 放行防火墙 → 自检
bin/chi proxy test      # 期望看到：经代理：中国 xx省
bin/chi serve           # 管理面板 https://<TS_FQDN>:8007/ui
```

面板（metacubexd）第一次打开时，后端地址填 `https://<TS_FQDN>:8007`，密钥填 `.env` 里的 `CLASH_SECRET`。在面板里可以看实时连接、切节点、把 `CN-media` 组一键切成 `DIRECT`（临时关闭回国）。

改了 `.env` 或 `config/mihomo/config.yaml.tmpl`（比如加站点）→ `bin/chi proxy apply`。

## 3. 让设备用上

### Google TV 盒子（推荐的主力）

```bash
# 盒子上先开开发者选项和 USB 调试（chi tv 不带参数会打印步骤）
bin/chi tv connect 10.0.0.23          # 盒子的 IP；第一次盒子上点“始终允许”
bin/chi tv proxy 10.0.0.23 on         # 系统代理 → Mac:7890
```

用 adb 设置代理是因为很多 Google TV 的设置菜单里**根本没有代理选项**。关闭：`chi tv proxy <ip> off`。
代价：Mac 关机或 mihomo 挂了，盒子会上不了网（所有流量都先到 Mac，只是大部分直连出去）。

**装哪个 B 站 App**——注意 Play 商店里的 “BiliBili” 是**国际版 bilibili.tv**，内容库完全不同，不是你要的：
- **云视听小电视**：B 站官方的大陆电视版。从 B 站官网下载 APK，然后 `bin/chi tv install 文件.apk`
- **BBLL**：流行的第三方 B 站电视客户端，遥控器操作体验好
- 爱奇艺 / 腾讯视频 / 芒果 TV 的大陆电视版（“银河奇异果”“云视听极光”等）同理侧载

**如果某个 App 不走系统代理**（有些 App 会绕过它，表现为仍然提示“地区限制”）：在盒子上装 **Clash Meta for Android** 或 **FlClash**，直接导入同一个订阅。它用 Android 的 VPN 接口接管整机流量，任何 App 都绕不过。缺点是订阅和规则要在盒子上再配一份，所以作为备选。

### 投影仪自带的国内系统

它本来就是国行系统，自带/应用市场里的 App 就是大陆版，只差一个大陆 IP：
- 如果 Wi‑Fi 设置里有「代理 → 手动」，填 Mac 的 IP 和 7890
- 如果能开开发者选项和 ADB，`chi tv proxy` 对它一样有效（它也是 Android 内核）
- 我**没法确认**极米 Z9X 这两项是否开放；不开放的话，就用 Google TV 盒子看

### 手机 / 笔记本（在家）

Wi‑Fi 设置 → HTTP 代理 → 手动 → Mac 的局域网 IP，端口 7890。在外面也想用：连着 Tailscale 时把服务器填成 Mac 的 Tailscale IP（100.x.y.z），已在白名单里。

## 4. 下载大陆限定视频（配合 Jellyfin 在投影上看）

yt-dlp 支持 B 站，走代理即可拿到大陆限定内容：

```bash
yt-dlp --proxy http://127.0.0.1:7890 --cookies cookies.txt "https://www.bilibili.com/video/BV..."
```

- `cookies.txt`：浏览器登录 B 站后用 cookie 导出扩展导出。不带 cookie 最高只有 480p；大会员内容需要大会员账号的 cookie。
- 更省事：启用 `media` stack 后直接 `chi fetch <B站链接>`（或 iPhone 分享菜单），MeTube 会自动走 mihomo，下完在 Jellyfin / 投影上看。见 [media.md](media.md)。

## 已知限制（说实话）

| 问题 | 说明 |
|---|---|
| 视频本身也走回国节点 | 规则里的 `bilibili` 包含 B 站 CDN 域名，所以视频流也绕道大陆，画质/流畅度受 VPN 带宽限制。可以试着在规则最前面加 `DOMAIN-SUFFIX,bilivideo.com,DIRECT` 让视频直连——**不保证有效**，有些播放地址和请求 IP 绑定，换 IP 就 403。自己试 |
| 版权番剧/电影 | 很多除了“大陆限定”还要**大会员**，代理解决不了付费墙 |
| 机房 IP | 部分平台会识别 VPN 的机房 IP 并限制。遇到了换节点或换商家（找“家宽/原生 IP”节点） |
| 条款 | 在美国用 VPN 合法；绕开地区限制违反平台用户协议，最坏情况是账号受限。个人观看一般没人管 |

## 我刻意没做的

- **哔哩漫游（BiliRoaming）等 Xposed 模块**：要 root + LSPosed，而且它依赖第三方“解析服务器”，你的账号凭据会经过陌生人的服务器。安全上不值得。
- **root / 刷机投影仪**：有变砖和失去保修的风险，收益只是省一个盒子。
- **Mac 做透明网关（TUN 模式）**：能让设备完全不用设代理，但会和 Tailscale 抢路由表，出问题时整个家里断网，排查成本高。真有需要再说。

## 排障

| 症状 | 排查 |
|---|---|
| `chi proxy test` 经代理仍是美国 | `chi proxy status` 看 CN 组有没有节点。0 个 → `CLASH_CN_FILTER` 没匹配上，打开面板看节点真实名字，改过滤规则 |
| 盒子上不了网 | Mac 上 `chi proxy status`；防火墙是否放行（brew 升级后 `chi proxy firewall`）；临时 `chi tv proxy <ip> off` |
| 某 App 仍提示地区限制 | 它绕过了系统代理 → 用盒子上的 Clash Meta for Android 方案；或者它用了规则里没有的域名 → 面板「连接」页看它连了哪些域名，加到模板规则里 |
| 订阅更新失败 | `chi proxy logs`。有的商家要求特定 User-Agent，在模板 `proxy-providers` 里加 `header` |
