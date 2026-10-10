# 媒体库：小型 NAS + 下载 + 投影

```
 iPhone 分享菜单 / chi fetch / MeTube 网页 / AI agent
                │  URL
                ▼
        MeTube（yt-dlp）──经 mihomo──► YouTube 直连 / B 站走回国
                │
                ▼
   $MEDIA_DIR/Downloads/<频道>/<日期> <标题> [id].mkv
                │
                ▼
           Jellyfin ──► onn 盒子（Jellyfin App，局域网 http://<Mac>:8096）
                    ──► iPhone（Swiftfin）/ Mac（浏览器）经 Tailscale https://<TS_FQDN>:8009
```

## 先说硬盘：256 GB 很紧

| 占用 | 大约 |
|---|---|
| macOS 本身 + 系统数据 | 35–50 GB |
| OrbStack 虚拟机 + 镜像（core/ai/media） | 10–15 GB |
| Ollama 一个 8B 模型 | ~5 GB |
| 留给系统更新和交换的余量（别低于这个） | ~30 GB |
| **能给媒体的** | **~60–100 GB** |

1080p 视频大约 0.5–2 GB/小时，所以 `MEDIA_MAX_GB=60` ≈ 40–80 小时内容，看完自动腾位置。这套设计就是“下载区当缓存”：
- `Downloads/` 超过上限，每天 05:47 自动从**最旧**的开始删（`chi schedule` 安装，`chi media clean --dry-run` 预览）
- 想留的挪到 `Keep/`，永远不删
- `photos`（Immich）在 256 GB 上别开

**真想当 NAS 用，买块外置 SSD**（1–2 TB 便携 SSD 不贵），格式化成 APFS，然后 `.env` 里 `MEDIA_DIR=/Volumes/<盘名>/media`、`MEDIA_MAX_GB` 调大，`chi up media`。外置盘要在“系统设置 → 通用 → 登录项与扩展”之外确保开机自动挂载（APFS 外置盘默认会）。

## 启用

```bash
# .env：CHI_STACKS 里加上 media（默认已加）
bin/chi up media
bin/chi serve
bin/chi schedule        # 装每日自动清理
```

第一次打开 `https://<TS_FQDN>:8009` 配 Jellyfin：
1. 建管理员账号，语言选中文
2. **添加媒体库**：
   - 类型「家庭视频和照片」，文件夹 `/media/Downloads` 和 `/media/Keep` —— YouTube/B 站下载
   - 类型「电影」→ `/media/Movies`；「节目」→ `/media/TV`（如果你自己放片）
3. 控制台 → 播放 → 转码：保持默认即可（容器里是 CPU 转码，M 系列芯片 1080p 实时没问题；onn 盒子大多数格式能直接播，不需要转码）
4. 控制台 → 用户：给自己和每个朋友各建一个账号
5. 可选：控制台 → API 密钥 → 新建，填进 `.env` 的 `JELLYFIN_API_KEY`，以后 `chi media scan` 立即刷新

## 下载

| 方式 | 怎么用 |
|---|---|
| 命令行 | `chi fetch 'https://www.youtube.com/watch?v=…'`（可选第二个参数：子文件夹） |
| 网页 | `https://<TS_FQDN>:8010` 贴链接；支持播放列表、频道订阅（MeTube 自带 Subscriptions） |
| iPhone 分享菜单 | 快捷指令，步骤在接入页面（`chi onboard` 生成）里 |
| AI agent | 任何能发 HTTP 的 agent / n8n：`POST http://127.0.0.1:8081/add`，JSON `{"url": "...", "quality": "1080"}` |
| **订阅（追剧）** | `chi media sub add <频道或播放列表> [文件夹] [标题正则]`，每 6 小时查一次，出新集自动下 |

### 订阅：追剧不用手动贴链接

腾讯视频、爱奇艺、优酷、芒果、华策、CCTV 在 YouTube 上都有官方频道，很多剧免费放全集。订阅**某部剧的播放列表**最合适；订阅整个频道要配标题正则，否则花絮、预告一起下，60G 几天就满。

```bash
chi media sub add 'https://www.youtube.com/playlist?list=PL…' 某某剧            # 一部剧的播放列表
chi media sub add 'https://www.youtube.com/@CCTVCH/videos' 新闻 '新闻联播'      # 整个频道，只要标题含“新闻联播”的
chi media sub            # 列表（含 id）
chi media sub rm <id>    # 退订
chi media sub check      # 立刻查一遍
```

加订阅时现有视频都算“已看过”，**只下之后的新视频**。想补旧集，把单集链接 `chi fetch` 进去。B 站的 UP 主 / 合集同样能订阅（大陆限定内容要先装好 `chi proxy`）。

- **B 站大陆限定内容**：装了 `chi proxy` 后，`chi up media` 会自动让 MeTube 走 mihomo，B 站自动走回国、YouTube 直连。高画质/大会员内容需要在 MeTube 网页里上传 B 站的 cookies 文件。
- **yt-dlp 每天自动更新到 nightly**（`YTDL_NIGHTLY_UPDATE_TIME`）。YouTube 隔三差五改反爬，旧版本很快失效——下载突然全挂，先等第二天自动更新，或 `chi restart media`。
- 下载完 Jellyfin 默认 12 小时内会扫到；想马上看到：`chi media scan`，或 Jellyfin 后台“扫描媒体库”。
- 版权说实话：YouTube 条款不允许下载；自己看属于灰色地带，搬运/传播不行。

## 直播电视：央视 / 卫视

`chi media iptv` 从 [iptv-org](https://github.com/iptv-org/iptv) 拉中国频道的公开直播源，**逐个试播，只留从这台 Mac 真能播的**（2026-10 实测 147 个里能播 64 个：CCTV1–17 大部分、湖南/东方/广东/安徽/河北卫视、风云剧场等），接进 Jellyfin 的「直播电视」。`chi schedule` 装了每天 05:27 自动重测（公开源经常换地址）。

- onn 上：Jellyfin App → 直播电视 → 频道。没有节目单（EPG），只能看“现在在播什么”
- 江苏、浙江、北京卫视等在列表里但限大陆 IP，Jellyfin 直连播不了。这类不值得为它们让 Jellyfin 全部走代理；想看用盒子上的回国 App
- 想加别的源：`.env` 里 `IPTV_M3U_URLS='url1 url2'`（空格分隔），然后 `chi media iptv`
- 公开源由各电视台自己的 CDN 提供，iptv-org 只做收集，不托管视频

## onn 4K Pro 盒子

我按 **onn 4K Pro（Walmart）** 写的——如果你的是别的型号告诉我。它支持 AV1 / VP9 / HEVC / H.264 和 Dolby Vision，YouTube/B 站下载的格式基本都能直接播。

1. 固定 IP（2026-10 已配好）：Mac mini **10.0.0.10**、onn **10.0.0.11**、Z9X **10.0.0.12**，都在路由器后台 `http://10.0.0.1` → Connected Devices 里预留了，备注写着设备名。
   - Mac 还在本机把 Wi‑Fi 设成了“手动 IP + DHCP 路由器”（`networksetup -setmanualwithdhcprouter Wi-Fi 10.0.0.10`）：这台 Xfinity 网关对在线设备的预留经常不生效（页面显示和实际租约对不上），本机写死更可靠。换路由器或网段时记得改回 `networksetup -setdhcp Wi-Fi`
   - Mac 的 Wi‑Fi 要用真实 MAC（系统设置 → Wi‑Fi → 详细信息 → 私有 Wi‑Fi 地址：关闭），否则 MAC 一轮换，路由器就当成新设备、IP 也跟着变
2. 盒子上 Play 商店装 **Jellyfin**（官方 Android TV 版）
3. 服务器地址：`http://<Mac的局域网IP>:8096`（盒子在局域网里，不需要 Tailscale）
4. 网络：它的网口只有 **百兆**，4K 高码率片子用 Wi‑Fi 6 反而更快；1080p 两者都够
5. 看 B 站大陆内容：见 [china-media.md](china-media.md)（`chi tv proxy <盒子IP> on` + 装云视听小电视/BBLL）

投影仪自带的国内系统：如果它的文件管理器支持 SMB，可以打开 Mac 的文件共享（系统设置 → 通用 → 共享 → 文件共享，添加 `MEDIA_DIR`，只读）直接播文件；但体验远不如盒子上的 Jellyfin。

## 为什么 Jellyfin 放容器而不是原生

之前在 ideas.md 里写过“原生跑才能用 VideoToolbox 硬件转码”。权衡后改成容器：
- onn 盒子能直接播几乎所有格式，**很少需要转码**；需要时 M 系列 CPU 软转 1080p 也够
- 容器版和其他服务一样由 `chi up/update/backup` 统一管理，原生版要单独维护
- 将来经常要给多个朋友同时转码 4K 时，再换原生（`brew install --cask jellyfin`，配置目录迁过去即可）
