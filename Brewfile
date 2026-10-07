# brew bundle --file=Brewfile   （chi bootstrap brew 会跑这个）
# 只放“服务器真的需要”的东西。容器运行时 / Tailscale / Ollama 由 bootstrap 按 .env 单独装。

brew "git"
brew "jq"          # 脚本里解析 JSON（tailscale status 等）
brew "restic"      # 备份：增量、去重、加密，支持本地盘/B2/S3
brew "btop"        # 看宿主机真实的 CPU/内存/温度（容器里看到的是虚拟机的）
brew "mas"         # 命令行装/更新 App Store 应用（可选）

# 可选：需要时取消注释
# cask "utm"       # 跑 Home Assistant OS 虚拟机（见 docs/ideas.md）
# brew "cloudflared"  # 公网暴露个别服务（见 docs/remote-access.md）
