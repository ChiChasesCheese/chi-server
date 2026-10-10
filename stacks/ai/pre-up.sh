#!/usr/bin/env bash
# chi up ai 之前检查宿主机 Ollama 在不在
. "$(dirname "$0")/../../scripts/lib.sh"
if curl -fsS --max-time 2 http://127.0.0.1:11434/api/version >/dev/null 2>&1; then
  ok "Ollama 在线：$(curl -fsS http://127.0.0.1:11434/api/version)"
else
  warn "宿主机 Ollama 没在跑（brew services start ollama）。Open WebUI 能起来，但没模型可用"
fi
