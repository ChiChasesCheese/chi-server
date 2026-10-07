#!/usr/bin/env bash
# 升级：brew 包 + 容器镜像。
#
# 为什么不用 Watchtower 自动更新：
#   - containrrr/watchtower 已于 2025-12 归档停更
#   - 更根本的原因：无人值守自动升级 = 某天半夜某个服务因为破坏性变更挂了而你不知道。
#     家用服务器的最佳实践是：每周/每两周手动跑一次 chi update，跑之前扫一眼 release notes（尤其 Immich）。
#   - 想要“有新版本时通知我”而不是“自动升级”，可以加 What's Up Docker (WUD)，见 docs/ideas.md
set -euo pipefail
. "$(dirname "$0")/lib.sh"
ensure_brew_path
load_env

if [ "${1:-}" != "--no-brew" ]; then
  log "brew update && upgrade"
  brew update
  brew upgrade
  # 注意：brew 升级 ollama 后需要重启服务
  if brew services list 2>/dev/null | grep -q '^ollama.*started'; then brew services restart ollama; fi
fi

require_docker
for s in $(resolve_stacks); do
  if [ "$s" = photos ]; then
    warn "photos：不自动换新版 Immich 的 compose。读完 release notes 后手动：stacks/photos/fetch.sh --force"
  fi
  log "$s: pull"
  compose "$s" pull
  compose "$s" up -d --remove-orphans
done

log "清理不再使用的旧镜像"
docker image prune -f >/dev/null
ok "升级完成。跑一下 chi doctor 确认"
