#!/usr/bin/env bash
# Immich 的 compose 文件更新频繁、有版本耦合（server / ML / Postgres 扩展版本要对齐），
# 官方明确建议用他们发布的 docker-compose.yml，不要自己改写。所以这里不入库，而是拉官方最新版。
#
# 生成：stacks/photos/compose.yaml（官方原样）和 stacks/photos/.env（官方模板 + 我们的路径/密码）
# 我们的修改只放在 compose.override.yaml 里（入库），升级时重新 fetch 不会冲突。
#
# 用法：stacks/photos/fetch.sh [--force]   --force 会重新下载 compose.yaml（.env 里的密码保留）
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/../../scripts/lib.sh"
load_env

BASE=https://github.com/immich-app/immich/releases/latest/download

if [ ! -f "$DIR/compose.yaml" ] || [ "${1:-}" = "--force" ]; then
  log "下载 Immich 官方 docker-compose.yml"
  curl -fsSL "$BASE/docker-compose.yml" -o "$DIR/compose.yaml"
  curl -fsSL "$BASE/example.env" -o "$DIR/example.env"
  ok "已更新 $DIR/compose.yaml —— 升级前请读 Immich 的 release notes，偶尔有破坏性变更"
fi

if [ ! -f "$DIR/.env" ]; then
  cp "$DIR/example.env" "$DIR/.env"
  chmod 600 "$DIR/.env"
  set_kv "$DIR/.env" DB_PASSWORD "$(rand_alnum 32)"
fi
# 每次都同步路径和时区（DATA_DIR 改了也能跟上）
set_kv "$DIR/.env" UPLOAD_LOCATION "$DATA_DIR/immich/library"
set_kv "$DIR/.env" DB_DATA_LOCATION "$DATA_DIR/immich/postgres"
set_kv "$DIR/.env" TZ "$TZ"
mkdir -p "$DATA_DIR/immich/library" "$DATA_DIR/immich/postgres" "$DATA_DIR/immich/db-dump"
ok "Immich .env 就绪（数据在 $DATA_DIR/immich）"
