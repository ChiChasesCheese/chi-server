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

调研结论（2026-10）：**“稳定”和“给 Clash 订阅”基本不能兼得**。

| 类型 | 代表 | 稳定性 | 能接 mihomo？ | 价格 |
|---|---|---|---|---|
| 持牌回国加速器 | 穿梭 Transocks（2017 年起，持工信部 VPN 牌照 B1-20251279）；快帆（要实名）、Sixfast 等 | 高 | **不能**，只有 App（有 Android TV 版）和自家路由器 | 穿梭约 ¥25/月、¥260/年；路由器 ¥699 |
| 带回国节点的机场 | EdNovas 云（2020 年起，个人站长） | 中：个人运营、退款暂停、回国节点 5 倍扣流量 | 能 | ¥30/月 200G（≈40G 回国流量） |
| 出国机场 | 大多数 | — | 没有大陆出口节点，没用 | — |

所以分两种用法：
- **只在电视上看**：买穿梭，盒子上装它的 TV 版 App。最稳，mihomo 用不上
- **还要 Mac 上下载 B 站大陆限定内容 / 让 Z9X 走 Mac 代理**：需要一个能给 Clash 订阅的服务（EdNovas 类），先买月付试

我**没法替你核实**任何一家对 B 站/爱奇艺的解锁效果，商家宣传都是自述。都先买最短期限。别从搜索结果直接点进机场网站，有仿冒站。

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

### onn 盒子：实际在用的是穿梭 TV 版（2026-10 配好）

穿梭不给 Clash 订阅，所以 onn 不走 Mac 上的 mihomo，而是自己跑穿梭：
- 穿梭 TV（Play 商店 `com.fobwifi.transocks.tv`）登录后默认智能分流：实测 B 站看到「中国 上海 电信」，美国网站仍从家里 Comcast 直连；局域网 10.x 不进隧道，Jellyfin 不受影响
- `chi tv vpn <onn的IP> com.fobwifi.transocks.tv` 设成始终开启，重启后自动连（没开 lockdown，穿梭挂了也能直连上网）
- B 站：云视听小电视（`com.xiaodianshi.tv.yst`），APK 来自 B 站官方 `dl.hdslb.com/mobile/latest/android_tv_yst/iBiliTV-master.apk`。它面向老 Android，`chi tv install` 会带兼容参数，并在 Play 保护拦截时提示你点「仍然安装」
- 穿梭官网的 TV 版 APK（4.0.8）在 Android 14 上装不了，用 Play 商店版
- 腾讯视频 / NBA：腾讯体育**没有电视版**，电视上看 NBA 用腾讯官方的「云视听极光」（`com.ktcp.video`）。APK 从 tv.qq.com 的「立即下载」拿（它调用 `tv.qq.com/homeconfig` 换成最新链接，CDN 是 vmat.gtimg.com）。NBA 在电视上要**腾讯体育 SVIP**，普通体育 VIP 只能在手机和电脑上用；用开会员的那个微信或 QQ 扫码登录
- 侧载的 App 不会自动更新；云视听小电视过几个月重新下载 `chi tv install` 一次

下面是 mihomo 方案（给 Clash 订阅类服务用），保留备查。

### Google TV 盒子（mihomo 方案）

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

### 极米 Z9X（国行系统）

局域网里它叫「Chi的Z9X 4K 旗舰版」，投屏服务宣告的是优酷 / 腾讯视频 —— 确认是**国行系统**，自带 App 就是大陆版，只差一个大陆 IP：
- Wi‑Fi 设置里有「代理 → 手动」：填 Mac 的 IP 和 7890（需要 Clash 订阅那条路）
- 能开开发者模式 + ADB 调试：`chi tv proxy <Z9X的IP> on`，效果同上
- 都不开放：要么用 onn 盒子看，要么买回国路由器（如穿梭路由器）让 Z9X 连它的 Wi‑Fi，整机回国

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
