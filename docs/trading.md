# 实盘交易机器人：放哪、怎么上线

还没定是加密货币交易所还是美股券商，这里按最严的需求写：**7×24 不停、出口 IP 固定**（交易所 API key 白名单要用）。
本文不是投资、税务或法律建议。交易所的事实 2026-10 核对过，以各家官方文档为准。

## 推荐架构：研究在家，实盘上云

| | Mac mini（家里） | 小云主机（$5–10/月） |
|---|---|---|
| 干什么 | 研究、回测、写代码、Claude、监控（Uptime Kuma） | **只跑实盘机器人** |
| 网络 | Comcast 动态 IP，Tailscale | 固定公网 IP，加入同一个 tailnet |
| 秘密 | 不放实盘 key | 实盘 key 只在这里 |

为什么实盘不放这台 Mac：

- **家里没有 SLA**：Comcast 断网、停电都会让机器人掉线；而且开着 FileVault，断电重启后要有人解锁才能起来（见 [macos-setup.md](macos-setup.md)），这段时间机器人完全不在。
- **动态 IP**：IP 一变，交易所 API key 的 IP 白名单就失效，下单全被拒；不开白名单 key 泄露的后果更大。
- **同一台机器上跑着 auto 模式的 AI agent、朋友的屏幕共享会话**：本机端口它们都能连（见 [onboarding.md](onboarding.md)），实盘 key 不该和它们待在一起。
- 云主机便宜、有固定 IP、机房供电和网络有保障，坏了重建一台也就几分钟。

做法：在交易所所在区域开一台最小规格 Linux VM → 装 Tailscale 加入 tailnet → 机器人用 systemd 跑（`Restart=always`）→ 从 Mac 通过 Tailscale SSH 部署、看日志。Mac 上继续回测和开发。

### 非要跑在 Mac 上

至少做到：

- 插网线；关掉 macOS 自动安装更新（系统设置 → 通用 → 软件更新 → 自动更新），升级手动挑时间做。
- **固定出口 IP**：开一台云 VM 当 Tailscale exit node（`sudo tailscale set --exit-node=<vm> --exit-node-allow-lan-access=true`）。注意这会让**整台 Mac** 的出网流量都绕过去，回国代理、媒体下载也一样；VM 挂了 Mac 就断网。要只让机器人走固定 IP，就得在 VM 上跑代理，机器人单独走代理。来源：[Tailscale exit nodes](https://tailscale.com/kb/1103/exit-nodes)
- 用 launchd 跑（`KeepAlive` = true，崩了自动拉起），不要靠 tmux 里手动开着。
- 接受现实：停电、断网、FileVault 重启时它就是不在，所以下面的「交易所侧保护」更不能省。

到这一步，其实已经付了一台 VM 的钱——直接把机器人放 VM 上更简单。

## 区域：机器人放哪

**延迟只对高频 / 做市有意义。** 分钟级以上的策略，家里到任何交易所几十到一两百毫秒都无所谓；选区域主要是为了少一跳、少出问题。

| 交易所 / 券商 | 撮合 / API 在哪 | VM 放哪 | 来源 |
|---|---|---|---|
| Coinbase Exchange（美国现货） | AWS us-east-1（use1-az4），Coinbase 注明可能不另行通知变更 | AWS us-east-1（弗吉尼亚） | [Coinbase systems & operations](https://docs.cdp.coinbase.com/exchange/introduction/systems-operations) |
| Coinbase Advanced Trade | 未找到官方说明，推测同上 | us-east-1 | 推测 |
| Coinbase International（INTX，非美国用户） | AWS ap-northeast-1（东京） | — | [INTX systems & operations](https://docs.cdp.coinbase.com/international-exchange/introduction/systems-operations) |
| Kraken（现货 + 衍生品） | Equinix 伦敦（自建机房，不在云上）；AWS 伦敦 eu-west-2 约 2 ms，美国约 60 ms | 伦敦（在意延迟时），否则随意 | [Kraken colocation](https://docs.kraken.com/exchange/guides/general/colocation) |
| Binance.com | 官方没公开；第三方测量普遍指向 AWS 东京 | — 美国居民不能用（见下） | [Glassnode latency monitor](https://latency.glassnode.com/cex/about)（第三方） |
| Binance.US | 未找到公开信息 | 美国东部即可 | — |
| OKX | 2026 年从香港迁到东京（第三方报道，OKX 文档没写机房）；美国用户走 OKX US，API 域名 `us.okx.com` | 美国用户：美国即可 | [OKX API 文档](https://www.okx.com/docs-v5/en/)、[Tardis 状态页](https://status.tardis.dev/incidents/bv68jvpj10z9)（第三方） |
| Interactive Brokers | 每个账户分配固定服务器：美东 `ndc1.ibllc.com`（纽约）、美中 `cdc1`（芝加哥）、欧洲 `zdc1`（苏黎世）等；模拟盘一律美国 | us-east-1 / 美东任意 | [IB Hosts & Ports](https://www.interactivebrokers.com/download/IB-Host-and-Ports.pdf)、[服务器位置](https://www.interactivebrokers.com/docs/tws-api/doc/tws-settings/connected-ib-server-location-in-tws) |
| Alpaca | GCP us-east4（北弗吉尼亚） | us-east-1 / us-east4 | [Alpaca 平台](https://docs.alpaca.markets/us/docs/alpaca-api-platform) |
| Schwab Trader API | 未找到公开信息 | 美国任意 | — |

**美国居民的限制**（你在 San Jose，就是美国人）：

- **Binance.com 不对美国用户开放**（2019 年起），美国用户用 Binance.US，而 Binance.US 也不对部分州开放（如纽约州），以其条款为准。[The Block 报道](https://www.theblock.co/post/27252/us-customers-to-be-blocked-from-trading-on-binance-com)、[Binance.US 条款](https://www.binance.us/terms-of-use)
- **OKX**：美国居民只能用 OKX US（OKX Inc.，2025 年上线），且只限其获准运营的州。[OKX 条款](https://www.okx.com/en-us/help/360021813691)
- **别用海外 VM 绕地区限制**：违反条款，被发现直接冻结账户，钱都拿不出来。VM 放海外只为延迟，前提是你本来就有资格用那家。

## 上线清单

**API key**

- [ ] 只开**交易**权限，**提现永远关**。
- [ ] IP 白名单只填 VM 的固定 IP（各家创建 key 时都有这个选项，以后台为准）。
- [ ] key 不放明文 `.env`：VM 上用 systemd credentials（`systemd-creds encrypt` + `LoadCredentialEncrypted=`，[文档](https://systemd.io/CREDENTIALS/)）或 1Password CLI（`op run`）；Mac 上用钥匙串（`security find-generic-password -w`）。
- [ ] key 不进 git、不进日志、不给 AI agent 看。

**交易所侧保护（机器人死了也有效）**

- [ ] 每笔开仓都挂**交易所侧止损单**，不靠机器人自己盯价。
- [ ] 开**断线自动撤单 / dead man's switch**，机器人定时续期，停止续期就撤掉所有挂单：

| 交易所 | 接口 | 用法 |
|---|---|---|
| Binance U 本位合约 | `POST /fapi/v1/countdownCancelAll`（`countdownTime` 毫秒，按 symbol，0 关闭） | 官方示例：每 30 s 续一次，倒计时 120000 ms。[文档](https://developers.binance.com/docs/derivatives/usds-margined-futures/trade/rest-api/Auto-Cancel-All-Open-Orders) |
| Binance 现货 | 没找到同类功能 | 只能靠止损单 + 自己的 watchdog |
| Kraken 现货 | `POST /0/private/CancelAllOrdersAfter`（`timeout` 秒，0 关闭） | 建议每 15–30 s 续，timeout 60 s；交易所维护前先关掉。[文档](https://docs.kraken.com/api/docs/rest-api/cancel-all-orders-after) |
| Kraken 合约 | `cancelallordersafter`（秒） | [文档](https://docs.kraken.com/api-reference/order-management/dead-mans-switch) |
| OKX | `POST /api/v5/trade/cancel-all-after`（`timeOut` 秒，0 或 10–120） | [文档](https://www.okx.com/docs-v5/en/#order-book-trading-trade-post-cancel-all-after) |
| Coinbase Exchange | FIX Logon tag 8013 `CancelOrdersOnDisconnect`（`Y` = 撤整个 profile 的单） | 只有 FIX 有；Advanced Trade REST/WS 没找到。[文档](https://docs.cdp.coinbase.com/exchange/fix-api/order-entry-messages/order-entry-messages5) |
| IBKR / Alpaca | 没找到 | IBKR 断开 API 后订单仍留在服务器上；有 `reqGlobalCancel` 可一键撤 |

**机器人自身**

- [ ] **熔断**：单笔最大亏损、单日最大亏损，触发就撤单、平仓（或只撤单）、停止，**人工确认后才恢复**。
- [ ] **重启先对账**：启动时先拉交易所的持仓、挂单、余额，和本地状态对齐后才允许下单。
- [ ] **幂等下单**：每个订单自己生成 client order id（Binance `newClientOrderId`、OKX `clOrdId`、Coinbase / Alpaca `client_order_id`），超时重试用同一个 id，避免重复下单。
- [ ] **时钟同步**：VM 开 chrony / systemd-timesyncd。Binance 签名请求要求时间戳在服务器时间 `recvWindow`（默认 5000 ms）内，否则拒单。[文档](https://developers.binance.com/docs/binance-spot-api-docs/rest-api/endpoint-security-type)
- [ ] **模拟盘 / testnet 跑满 2 周**，再用小资金实盘。
- [ ] **日志 / 审计**：每个决策、下单、成交、撤单都写结构化日志（带 client order id），定期备份到别处。

**监控和告警**

- [ ] 告警发 ntfy 或 Telegram：成交、熔断、报错、断线。
- [ ] **心跳到 healthchecks.io**：机器人每分钟 ping 一次，断了由外部发通知——不依赖家里这台 Mac。
- [ ] Uptime Kuma（Mac 上）通过 Tailscale 监控机器人的 `/health`（只监听 Tailscale IP）。容器里解析不了 MagicDNS 名的话直接填 VM 的 100.x 地址。

## IBKR 特有的麻烦

IBKR 的 API 要连一个一直开着的 **IB Gateway**（或 TWS），它是带图形界面的 Java 程序：

- **每天重启**：官方建议 API 用户设置「Auto restart」，每天自动重启而不用重新登录。[IBKR 文档](https://www.interactivebrokers.com/docs/tws-api/doc/tws-settings/daily-weekly-reauthentication)
- **每周重新认证**：IBC 文档原话，认证“only required the first time during the week that TWS or Gateway run after 01:00 ET on Sunday”；IBKR 自己的文档说周期从周一开始，以实测为准。每周一次要在手机 IBKR Mobile 上**手动批准 2FA**。
- **IBC**（[IbcAlpha/IBC](https://github.com/IbcAlpha/IBC/blob/master/userguide.md)）能自动填登录框、点掉弹窗、配合 `AutoRestartTime` 每天重启；但 2FA 它帮不了（“IBC cannot itself assist in the process”）。`ReloginAfterSecondFactorAuthenticationTimeout=yes` 能在你没及时批准时重新发起登录。
- 在 Linux VM 上要配虚拟显示（Xvfb）；社区有打包好 IB Gateway + IBC 的 Docker 镜像，可以省事，用前看清维护状态。
- IBKR 不用 API key、也没有 IP 白名单，所以「固定 IP」对它不是硬需求；7×24 + 每周人工 2FA 才是。

## 税务 / 记录

保留每一笔成交记录（交易所导出 + 自己的日志），报税要用；具体问会计。
