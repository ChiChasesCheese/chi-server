#!/usr/bin/env bash
# restic 备份 $DATA_DIR。
#
# 策略（为什么这样设计）：
#   1. SQLite 类应用（Uptime Kuma、Vaultwarden、n8n、Open WebUI）在写入时直接复制文件可能得到损坏的库。
#      最简单可靠的做法：短暂停掉这些容器 → 快照 → 立刻启动。增量备份通常几十秒。
#   2. Immich 的 Postgres 不停机，用 pg_dumpall 导出 SQL（官方推荐做法），原始 postgres 目录排除不备。
#   3. Immich 照片库是只增不改的文件，在线备份即可，不用停（否则首次几百 GB 会停很久）。
#
# 恢复演练见 docs/operations.md。没演练过的备份 = 没有备份。
set -euo pipefail
. "$(dirname "$0")/lib.sh"
ensure_brew_path
load_env
have restic || die "没装 restic（brew install restic）"
export RESTIC_REPOSITORY RESTIC_PASSWORD_FILE

action="${1:-run}"

case "$action" in
  init)
    restic cat config >/dev/null 2>&1 && { ok "仓库已存在：$RESTIC_REPOSITORY"; exit 0; }
    restic init
    ok "restic 仓库已初始化：$RESTIC_REPOSITORY"
    ;;
  snapshots) restic snapshots ;;
  check)     restic check --read-data-subset=5% ;;
  run)
    restic cat config >/dev/null 2>&1 || die "仓库不可用：$RESTIC_REPOSITORY（外置盘挂上了吗？没 init 就先 chi backup init）"
    require_docker

    stacks="$(resolve_stacks)"

    # --- Immich：在线导出数据库 ---
    if docker ps --format '{{.Names}}' | grep -qx immich_postgres; then
      log "导出 Immich 数据库"
      docker exec immich_postgres pg_dumpall --clean --if-exists --username=postgres \
        | gzip >"$DATA_DIR/immich/db-dump/immich.sql.gz.tmp"
      mv "$DATA_DIR/immich/db-dump/immich.sql.gz.tmp" "$DATA_DIR/immich/db-dump/immich.sql.gz"
    fi

    # --- 应用数据：停容器 → 备份 → 启动（trap 保证出错也会拉起来）---
    stopped=""
    restart_all() {
      for s in $stopped; do compose "$s" start >/dev/null 2>&1 || warn "$s 启动失败，手动 chi up $s"; done
    }
    trap restart_all EXIT
    for s in $stacks; do
      [ "$s" = photos ] && continue
      log "暂停 $s"
      compose "$s" stop >/dev/null
      stopped="$stopped $s"
    done

    log "备份应用数据（不含 Immich 照片库）"
    restic backup "$DATA_DIR" \
      --exclude "$DATA_DIR/immich" \
      --tag apps --host "${CHI_HOSTNAME:-chi-mini}"

    restart_all
    stopped=""
    trap - EXIT
    ok "服务已恢复"

    # --- Immich 照片库 + 数据库导出：在线备份 ---
    if [ -d "$DATA_DIR/immich" ]; then
      log "备份 Immich 照片库 + 数据库导出（在线）"
      restic backup "$DATA_DIR/immich/library" "$DATA_DIR/immich/db-dump" \
        --tag photos --host "${CHI_HOSTNAME:-chi-mini}"
    fi

    # 也备份 .env（含 n8n 加密密钥等）—— 它在仓库目录但不在 git 里
    restic backup "$CHI_ROOT/.env" --tag config --host "${CHI_HOSTNAME:-chi-mini}"

    log "清理旧快照：保留 7 天 / 4 周 / 6 个月"
    restic forget --prune --group-by host,tags \
      --keep-daily 7 --keep-weekly 4 --keep-monthly 6
    ok "备份完成"
    ;;
  *) die "用法: chi backup [init|run|snapshots|check]" ;;
esac
