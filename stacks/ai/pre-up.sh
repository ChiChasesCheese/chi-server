#!/usr/bin/env bash
# Before chi up ai: check that Ollama is running on the host
. "$(dirname "$0")/../../scripts/lib.sh"
if curl -fsS --max-time 2 http://127.0.0.1:11434/api/version >/dev/null 2>&1; then
  ok "Ollama is up: $(curl -fsS http://127.0.0.1:11434/api/version)"
else
  warn "Ollama is not running on the host (brew services start ollama). Open WebUI will start but have no models"
fi
