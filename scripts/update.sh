#!/usr/bin/env bash
# Upgrade: brew packages + container images.
#
# Why not auto-update with Watchtower:
#   - containrrr/watchtower was archived (unmaintained) in 2025-12
#   - More fundamentally: unattended auto-upgrades = some night a service breaks on a breaking change and you don't know.
#     Best practice for a home server: run chi update by hand every week or two, after skimming the release notes
#     (especially Immich).
#   - If you want "tell me when there's a new version" rather than "upgrade automatically", add What's Up Docker (WUD);
#     see docs/roadmap.md
set -euo pipefail
. "$(dirname "$0")/lib.sh"
ensure_brew_path
load_env

if [ "${1:-}" != "--no-brew" ]; then
  log "brew update && upgrade"
  brew update
  brew upgrade
  # Note: after brew upgrades ollama the service needs a restart
  if brew services list 2>/dev/null | grep -q '^ollama.*started'; then brew services restart ollama; fi
  # After a mihomo upgrade the binary path changes; re-allow it in the firewall or LAN devices can't reach the proxy
  if brew services list 2>/dev/null | grep -q '^mihomo.*started'; then
    "$CHI_ROOT/scripts/proxy.sh" firewall
    brew services restart mihomo
  fi
fi

require_docker
for s in $(resolve_stacks); do
  if [ "$s" = photos ]; then
    warn "photos: the Immich compose file is not swapped automatically. After reading the release notes run: stacks/photos/fetch.sh --force"
  fi
  log "$s: pull"
  compose "$s" pull
  compose "$s" up -d --remove-orphans
done

log "Removing unused old images"
docker image prune -f >/dev/null
ok "Upgrade done. Run chi doctor to confirm"
