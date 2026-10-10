# macOS 装机清单

脚本能自动化的都在 `chi bootstrap` 里了。这里是**脚本做不了、必须你手点**的部分，以及一个必须你自己做的决定（FileVault）。

## 0. 装机前（物理接触，一次性）

- [ ] **插网线**。Wi‑Fi 也能用，但 FileVault 预启动 SSH 解锁实测只在有线下可靠，而且服务器本来就该有线。
- [ ] 系统升到最新（系统设置 → 通用 → 软件更新）。本仓库假设 **macOS 26 Tahoe 或更新**，Apple Silicon。
- [ ] 创建你的管理员账户。建议这台机器**只有这一个日常账户**，所有服务跑在它下面。
- [ ] Apple ID：如果以后想用 iMessage 网关之类，就登一个；否则可以不登。**不建议登你主力的 iCloud 并开照片/文稿同步**——那会把你全部的 iCloud 数据拉到服务器上。
- [ ] 路由器里给它**固定 IP**（DHCP 保留）。Tailscale 不依赖这个，但局域网访问、FileVault 局域网解锁要用。
- [ ] 可选：**UPS**（几百块的那种就行）。断电是家用服务器最常见的“故障”，UPS 能扛过闪断，配合下面 FileVault 的选择更省心。
- [ ] 可选：**HDMI 假负载**（几块钱）。无显示器时屏幕共享的分辨率会很奇怪，插一个就好。

## 1. 系统设置里手点（bootstrap 前）

- [ ] **隐私与安全性 → 完全磁盘访问权限 → 加上“终端”**（或你用的 iTerm 等）。
  否则 `systemsetup`（开 SSH、死机重启）会失败。脚本失败也会告诉你，但先开省事。
- [ ] **通用 → 共享 → 远程登录**：打开，“允许访问”选“仅这些用户”→ 只留你自己。
- [ ] **通用 → 共享 → 屏幕共享**：打开（同样只允许你自己）。重启后需要图形登录时就靠它，经 Tailscale 用 `vnc://<tailscale-ip>` 连。
- [ ] **通知**：把不需要的都关了，服务器不需要弹窗。

然后：

```bash
git clone https://github.com/chichasescheese/chi-service.git ~/chi-service
cd ~/chi-service && bin/chi init && open -e .env   # 看一遍，改 CHI_STACKS 等
bin/chi bootstrap
```

## 2. 必须你做的决定：FileVault

核心矛盾：**OrbStack / Colima / Ollama 都是“用户登录后”才启动的**（macOS 上 Docker 本质是个 App）。所以机器重启后，必须有用户登录，服务才会回来。而 FileVault 开着时，macOS **不允许自动登录**。

### 模式 A：FileVault 关 + 自动登录（可用性优先）

- 断电、死机、系统更新后 → **完全无人值守恢复**。
- 代价：机器被偷，硬盘数据可读。
- 设置：系统设置 → 隐私与安全性 → FileVault 关闭（解密要几十分钟）；用户与群组 → 自动登录 → 选你的账户。
- 缓解：Vaultwarden 本身是端到端加密的，偷了也只是密文；真正暴露的是照片和 n8n 里存的凭据（后者被 `N8N_ENCRYPTION_KEY` 加密，但密钥就在同一台机器的 `.env` 里，所以等于没加密——说实话）。

### 模式 B：FileVault 开（安全优先）

- **计划内重启**（系统升级）：用 `sudo fdesetup authrestart`，它会预先授权一次解锁，重启后**自动解锁并登录**，服务正常回来。永远用这个代替“重新启动”菜单。
- **计划外重启**（断电）：机器停在解锁阶段。macOS 26 起可以 **SSH 预启动解锁**：
  ```bash
  ssh 你的用户名@<局域网IP>    # 用账户密码，不是密钥；会提示 host key 变了，正常（预启动环境的 key 不同）
  ```
  解锁后系统继续启动。如果停在登录窗口，用屏幕共享登录一次。
- ⚠️ 关键限制：预启动阶段 **Tailscale 还没起来**，所以这一步**只能从局域网做**。你人在外地 → 需要家里有另一台常开的、在 tailnet 里的设备做跳板（树莓派、带 Tailscale 的路由器、NAS 都行）。没有的话，断电 = 等你回家。
- ⚠️ 未验证项：我**无法确认**“SSH 仅密钥登录”（`CHI_SSH_KEY_ONLY=1`）是否会影响预启动解锁（它需要密码）。所以脚本默认不开仅密钥登录。如果你要开，**人在机器旁边时**重启一次验证。

### 我的建议

- 机器放家里、你经常不在家、没有跳板设备 → **A**。家用服务器的首要任务是“一直在”，而家庭入室盗窃专门偷 Mac mini 并提取数据的威胁模型概率很低。
- 有跳板设备 + UPS，或者上面放了你特别在意的东西 → **B**。
- 不管选哪个，**都做好 `chi backup`**——磁盘坏和机器丢比黑客常见得多。

## 2.5 个人开发环境（chifig）

`chi bootstrap` 的第一步 `dotfiles` 会调用你的 [chifig](https://github.com/ChiChasesCheese/chifig)（chezmoi）：zsh / git / tmux / Ghostty / mise / uv 等，以及 `keyboard` 模块（Windows 键盘 Alt→Cmd、Win→Ctrl）。它会先把现有的 `.zshrc`、`.gitconfig` 等备份到 `~/.local/state/chifig-backup/<日期>/` 再覆盖。以后更新：`chezmoi update` 或再跑一次 `chi bootstrap dotfiles`。

## 3. bootstrap 之后

- [ ] Tailscale 管理后台：这台机器 → **Disable key expiry**（否则 180 天后掉线，而那时你多半不在家）。
- [ ] Tailscale 管理后台 → DNS：打开 **MagicDNS** 和 **HTTPS Certificates**（`chi serve` 需要）。
- [ ] `bin/chi init` 再跑一次，填 `TS_FQDN`。
- [ ] OrbStack：设置里确认 **Start at login** 已勾（脚本尝试自动设置，失败会提示）。
- [ ] SSH 密钥：在你自己的电脑上 `ssh-copy-id 用户名@chi-mini`，验证能免密登录。
  想禁用密码登录：`.env` 里加 `CHI_SSH_KEY_ONLY=1`，`bin/chi bootstrap macos`。先读上面 FileVault 模式 B 的警告。
- [ ] **Time Machine**（推荐，和 restic 互补）：插一块外置盘，系统设置 → 通用 → Time Machine。它管整机系统，restic 管服务数据异地备份。
- [ ] 跑 `bin/chi doctor`。

## 4. 系统升级怎么做

```bash
chi backup run                  # 先备份
softwareupdate --list
sudo softwareupdate -i -a       # 下载安装（不重启）
sudo fdesetup authrestart       # FileVault 开着时；没开就 sudo shutdown -r now
# 回来后
chi doctor
```

`scripts/macos.sh` 已设置为：自动下载、自动装安全补丁，但**不自动装系统更新**——避免半夜重启卡在 FileVault 解锁上。
