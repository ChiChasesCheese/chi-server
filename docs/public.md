# 公网访问：public stack（Cloudflare Tunnel）

把**个别**网页 / API 公开给没装 Tailscale 的人或第三方回调。自己和家人用，仍然一律走 Tailscale（[remote-access.md](remote-access.md)）。

```
访客 ──HTTPS──► Cloudflare 边缘（TLS 在这里终止，WAF / Access / 限流）
                    ▲
                    │ cloudflared 主动连出（出站 7844 端口，QUIC，不通时回落 HTTP2）
                    │
  Mac mini ── chi-cloudflared ──(网络 public, internal)──► chi-public-hello / 你的应用
```

- 路由器不开任何端口，家里 IP 不出现在 DNS 里；Comcast 换 IP 也不影响（连接是出站的）。
- 代价：Cloudflare 能看到明文流量；免费版单个请求体最大 100 MB；家里断电/断网 = 网站下线。

## Tunnel 还是 `tailscale funnel`？

| | Cloudflare Tunnel（本 stack） | `tailscale funnel` |
|---|---|---|
| 域名 | 你自己的域名（要托管到 Cloudflare） | 只能 `<机器>.<tailnet>.ts.net` |
| 端口 | 标准 443，按子域名分应用 | 只能 443 / 8443 / 10000 |
| 带宽 | 受你的上行限制 | 另有不可调的带宽上限 |
| TLS | 在 Cloudflare 终止（他们看得到内容） | 在你的机器上终止（中继看不到内容） |
| 认证 / 防护 | Access、WAF、限流都现成 | 没有，应用自己负责 |
| 适合 | 长期公开的小网站 / API / webhook | 临时演示、偶尔给别人看一眼、临时收个回调 |

临时用 funnel 就行（`tailscale funnel 3000`，用完 `tailscale funnel reset`），不用开这个 stack。

## 第一次配置

1. 域名托管到 Cloudflare（免费版即可）。
2. Cloudflare 后台 → **Networking → Tunnels → Create a tunnel**（旧界面叫 Zero Trust → Networks → Tunnels），起名 `chi-mini`，环境选 Docker，复制命令里 `--token` 后面那串。
3. `.env`：
   ```bash
   bin/chi init                     # 补上新键 CF_TUNNEL_TOKEN / PUBLIC_DOMAIN
   # 编辑 .env：
   CF_TUNNEL_TOKEN=eyJhIjoi...      # 第 2 步的 token
   PUBLIC_DOMAIN=hello.example.com  # 只给 Homepage 卡片用
   CHI_STACKS="core ai media public"
   ```
4. 启动并看日志：
   ```bash
   bin/chi up public
   bin/chi logs public cloudflared  # 看到 Registered tunnel connection ... location=sjcXX 就通了（一般 4 条）
   bin/chi ps public                # cloudflared 应为 (healthy)
   ```
5. 后台回到这个隧道 → **Routes → Add route → Published application**（旧界面叫 Public Hostname）：子域名 `hello`、选域名、Service URL 填 `http://hello:80`。
6. 打开 `https://hello.example.com`，看到 whoami 的输出（Hostname / IP / 请求头）就是整条链路通了。
7. `bin/chi up core` 让 Homepage 读到 `PUBLIC_DOMAIN`（「公网」分组）。

关掉公网入口：`.env` 里清空 `CF_TUNNEL_TOKEN` 再 `bin/chi up public`（pre-up.sh 会删掉 chi-cloudflared），或者直接 `bin/chi down public`。

### 实现细节

- `stacks/public/pre-up.sh` 在每次 `chi up public` 前根据 `CF_TUNNEL_TOKEN` 写 `stacks/public/.env`（`COMPOSE_PROFILES=tunnel` 或空），cloudflared 在 `tunnel` profile 里，没 token 就不启动，免得它无限重启。
- 健康检查：镜像是 distroless，没有 shell / curl，所以用 exec 形式调用自带的 `cloudflared tunnel ready`（请求 `/ready`，至少有一条连接时返回 200）。metrics 只听容器内 `127.0.0.1:2000`，同网络的应用访问不到。
- `restart: unless-stopped`：Mac 重启 / OrbStack 重启后自动重连。

## 加一个新的公开应用

1. 在 `stacks/public/compose.yaml` 里加服务：`container_name: chi-public-<名字>`，`networks: [public]`，**不写 `ports`**，数据放 `${DATA_DIR}/public-<名字>`。
2. 只有确实要访问外网（调第三方 API 等）才再加 `egress` 网络——加了它就能访问宿主机的 127.0.0.1 端口（见下面「隔离」）。
3. `bin/chi up public`。
4. Cloudflare 后台这个隧道 → Routes → Add route → Published application：Service URL 填 `http://<服务名>:<容器端口>`。**永远不要填 `localhost`、`host.docker.internal` 或宿主机 IP**——cloudflared 接在 egress 网络上，填了就能把宿主机上的 Dozzle / Kuma 之类直接公开出去。
5. 有后台 / 管理路径的，配 Access（下一节）。
6. Uptime Kuma 加一个对公网地址的 HTTP 监控（从外面绕一圈回来，能顺便发现隧道断了）。

已有的、在别的 stack 里的服务（比如 n8n 只想公开 webhook）：在那个 stack 的 compose 里给服务加外部网络 `chi-public_public`（`networks: { public: { external: true, name: chi-public_public } }`，先 `chi up public` 让网络存在），Service URL 填 `http://chi-n8n:5678`。注意它同时还在自己 stack 的普通网络上，能访问宿主机——所以这类服务必须配 Access，只放行回调路径。

## Cloudflare Access：给管理路径加登录

**Zero Trust → Access controls → Applications → Create new application → Self-hosted**：

- Public hostname 填子域名，需要的话加路径（如 `app.example.com/admin`）。
- Policy：Action = Allow，Include = Emails = 你的邮箱。Access 默认拒绝，没匹配 Allow 的一律挡在 Cloudflare 外面，请求根本到不了家里。
- 登录方式用 One-time PIN（邮箱验证码）就够，不用接 IdP。
- 需要第三方直接调的路径（如 n8n 的 `/webhook/`）：再建一个更具体路径的应用，策略用 **Bypass**。
- 免费版有人数上限，个人用足够（以 Cloudflare 官网为准）。

Cloudflare 账号本身也是钥匙：谁能登录你的 Cloudflare，谁就能改隧道路由。**开 2FA**。

## 防护基础（免费版）

- **WAF**：域名 → Security。免费版自带 Cloudflare Free Managed Ruleset；可以加少量自定义规则，比如只允许某些国家、挡掉 `/wp-admin` 这类扫描路径。
- **限流**：免费版 1 条 Rate limiting rule，按 IP 计数、10 秒窗口。给登录 / 写接口加一条，例如同一 IP 10 秒内超过 20 次就挡。
- **Bot Fight Mode**、Security Level 可按需开；被打时临时开 **Under Attack mode**。
- 应用拿到的客户端 IP 是 cloudflared 的，真实访客 IP 在请求头 `CF-Connecting-IP`。

## 容量预期（121 Mbps 上行）

- 121 Mbps ≈ 15 MB/s，这是所有出站流量共用的：公网访客、Tailscale 远程看片、restic 异地备份都在抢它。
- 小 API / JSON：瓶颈在应用和 Mac 本身，不在带宽，每秒几百个请求没问题。
- 网页：一个 2 MB 的页面，上行跑满每秒也就 7 次左右完整加载；静态资源（js/css/图片）让 Cloudflare 缓存，家里只出 HTML 和 API。
- **不要拿来公开视频 / 大文件**：Cloudflare 条款要求视频和大文件走他们的付费产品（Stream / R2 等），否则可能被限制；单个上传 100 MB 封顶；1080p 一路 5–8 Mbps，十几个人同时看就把上行吃满。Jellyfin / Immich 留在 Tailscale 里。

## Comcast 条款（说实话）

Xfinity 的 Acceptable Use Policy 写明禁止在家里运行“提供网络内容的服务器”（举例包括 web hosting），对程序/设备那一条有“personal and non-commercial residential use”的例外。个人、非商业、小流量的项目一般没人管；**别拿家宽跑商业服务或大流量站点**，真要做就上 VPS / Cloudflare Pages。（这不是法律意见。）

## 绝对不要公开的

- Dozzle（容器日志，常含密钥）、Uptime Kuma、Homepage（挂着 docker.sock）
- 任何挂 `docker.sock` 的东西 = 整台机器的 root
- Open WebUI（尤其是管理后台）、Ollama 11434（无认证）
- mihomo 面板 9090 和代理端口 7890（会变成公开代理）
- MeTube（无认证，任何人都能让你的机器下载东西）
- Vaultwarden、n8n 编辑器（要公开也只能在 Access 后面）
- SSH / VNC / 屏幕共享

## 隔离：实测结论和自检

OrbStack 下，**普通 docker 网络里的容器能通过 `host.docker.internal` 访问宿主机上只绑 127.0.0.1 的端口**（实测 Kuma 3001、Dozzle 8080 都能访问到）。“端口绑 127.0.0.1”只防局域网，不防同一台机器上的容器。所以：

- 公开的应用放在 `internal: true` 的 `public` 网络：没有网关，解析不到 `host.docker.internal`，出不了外网。被攻破了也碰不到宿主机上的管理界面。
- 只有 cloudflared（和你明确加了 `egress` 的应用）能出网——也因此能访问宿主机。
- 管理类服务仍然坚持只绑 127.0.0.1（现有约定），并各自开着登录。

自检（whoami 镜像里没有 wget，用一个临时 busybox 容器接到同一网络测）：

```bash
docker run --rm --network chi-public_public busybox:stable sh -c '
  wget -qO- -T3 http://hello:80 >/dev/null && echo "hello 可达（对）"
  wget -qO- -T3 http://host.docker.internal:3001 >/dev/null 2>&1 && echo "能访问宿主机 Kuma（不对！）" || echo "访问不到宿主机（对）"
  wget -qO- -T3 http://1.1.1.1 >/dev/null 2>&1 && echo "能出外网" || echo "出不了外网（对）"'
```

加了 `egress` 的应用，用 `docker exec chi-public-<名字> wget -qO- -T3 http://host.docker.internal:3001` 测（镜像里得有 wget），能访问到是预期的——记住这个风险。

## 家里断 = 网站断

没有 SLA。停电、Comcast 故障、macOS 更新重启、开了 FileVault 后重启卡在解锁界面，这些时候访客看到的是 Cloudflare 的错误页（隧道断开时一般是 Error 1033，应用挂了是 502）。要求高可用的东西别放家里。

## 参考

- 远程管理型隧道创建：<https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/get-started/create-remote-tunnel/>
- 运行参数（`--token`/`TUNNEL_TOKEN`、`--metrics`/`TUNNEL_METRICS`、`--no-autoupdate`）：<https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/configure-tunnels/run-parameters/>
- 隧道 metrics：<https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/monitor-tunnels/metrics/>
- 自托管应用接 Access：<https://developers.cloudflare.com/cloudflare-one/access-controls/applications/http-apps/self-hosted-public-app/>
- 限流规则（各套餐额度）：<https://developers.cloudflare.com/waf/rate-limiting-rules/>
- 上传大小限制（413）：<https://developers.cloudflare.com/support/troubleshooting/http-status-codes/4xx-client-error/error-413/>
- Cloudflare 服务条款（CDN 视频/大文件）：<https://www.cloudflare.com/service-specific-terms-application-services/>
- Tailscale Funnel：<https://tailscale.com/kb/1223/funnel>
- Xfinity Acceptable Use Policy：<https://www.xfinity.com/corporate/customers/policies/highspeedinternetaup>
