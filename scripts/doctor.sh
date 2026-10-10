#!/usr/bin/env bash
# 体检：只读，不改任何东西。每一项 ✓ / ! 都告诉你为什么重要。
set -uo pipefail
. "$(dirname "$0")/lib.sh"
ensure_brew_path

fails=0
bad() { warn "$*"; fails=$((fails + 1)); }

log "系统"
if is_macos; then
  ok "macOS $(sw_vers -productVersion) / $(uname -m)"
  [ "$(uname -m)" = arm64 ] || bad "不是 Apple Silicon，部分功能（FileVault SSH 解锁、Metal 推理）不可用"

  pm="$(pmset -g)"
  echo "$pm" | grep -Eq '^ *sleep +0' && ok "永不睡眠" || bad "系统会睡眠 → chi bootstrap macos"
  echo "$pm" | grep -Eq 'autorestart +1' && ok "断电后自动开机" || bad "断电不会自动开机 → chi bootstrap macos"

  fw="$(/usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate 2>/dev/null)"
  case "$fw" in *enabled*) ok "防火墙开启" ;; *) bad "防火墙关闭" ;; esac

  nc -z 127.0.0.1 22 >/dev/null 2>&1 && ok "SSH 在监听" || bad "SSH 没开（系统设置 → 共享 → 远程登录）"

  fv="$(fdesetup status 2>/dev/null)"
  case "$fv" in
    *"is On"*) warn "FileVault 开：断电重启后需先远程/本地解锁（见 docs/macos-setup.md）" ;;
    *) ok "FileVault 关：可无人值守重启（代价：机器被偷数据可读）" ;;
  esac

  au="$(defaults read /Library/Preferences/com.apple.loginwindow autoLoginUser 2>/dev/null || true)"
  [ -n "$au" ] && ok "自动登录用户：$au" || warn "没开自动登录：重启后没人登录，Docker/Ollama 不会启动"

  df_pct="$(df -P / | awk 'NR==2 {gsub("%",""); print $5}')"
  [ "$df_pct" -lt 85 ] && ok "系统盘已用 ${df_pct}%" || bad "系统盘已用 ${df_pct}%（>85%）"
else
  warn "不是 macOS，跳过系统检查"
fi

log "网络"
if have tailscale; then
  if tailscale status >/dev/null 2>&1; then
    ok "Tailscale 在线：$(tailscale ip -4 2>/dev/null | head -n1)"
  else
    bad "Tailscale 没登录 → chi bootstrap tailscale"
  fi
else
  bad "没装 Tailscale → chi bootstrap tailscale"
fi

log "配置"
if [ -f "$CHI_ROOT/.env" ]; then
  load_env
  ok ".env 存在，启用的 stack：$(resolve_stacks)"
  [ -n "${TS_FQDN:-}" ] && ok "TS_FQDN=$TS_FQDN" || bad "TS_FQDN 为空 → chi init"
  [ -f "${RESTIC_PASSWORD_FILE:-/nonexistent}" ] && ok "restic 密码文件存在" || bad "restic 密码文件不存在 → chi init"
else
  bad "没有 .env → chi init"
fi

log "容器"
if docker_ready; then
  ok "docker 可用（$(docker version --format '{{.Server.Version}}' 2>/dev/null)）"
  if [ -f "$CHI_ROOT/.env" ]; then
    for s in $(resolve_stacks); do
      running="$(docker ps --filter "label=com.docker.compose.project=chi-$s" --format '{{.Names}}' | tr '\n' ' ')"
      unhealthy="$(docker ps --filter "label=com.docker.compose.project=chi-$s" --filter health=unhealthy --format '{{.Names}}' | tr '\n' ' ')"
      if [ -z "$running" ]; then bad "$s：没有运行中的容器 → chi up $s"
      elif [ -n "$unhealthy" ]; then bad "$s：不健康 → $unhealthy（chi logs $s）"
      else ok "$s：$running"; fi
    done
  fi
else
  bad "docker 连不上（OrbStack/Colima 没启动？）"
fi

if [ -f "$CHI_ROOT/.env" ] && case " $(resolve_stacks) " in *" ai "*) true ;; *) false ;; esac; then
  log "Ollama"
  if v="$(curl -fsS --max-time 2 http://127.0.0.1:11434/api/version 2>/dev/null)"; then
    ok "Ollama 在线 $v；已有模型：$(ollama list 2>/dev/null | awk 'NR>1 {print $1}' | tr '\n' ' ')"
  else
    bad "Ollama 不在线 → brew services start ollama"
  fi
fi

if [ -n "${CLASH_SUBSCRIPTION_URL:-}" ]; then
  log "回国分流"
  if nc -z 127.0.0.1 "${CLASH_PORT:-7890}" >/dev/null 2>&1; then
    via="$(curl -fsS --max-time 10 -x "http://127.0.0.1:${CLASH_PORT:-7890}" https://api.bilibili.com/x/web-interface/zone 2>/dev/null | jq -r '.data.country' 2>/dev/null || true)"
    [ "$via" = "中国" ] && ok "mihomo 在线，B 站出口：中国" || bad "mihomo 在线但 B 站出口是「${via:-未知}」→ chi proxy status"
  else
    bad "mihomo 没在监听 :${CLASH_PORT:-7890} → chi proxy install"
  fi
fi

echo
if [ "$fails" -eq 0 ]; then ok "全部正常"; else warn "$fails 项需要处理"; fi
exit "$fails"
