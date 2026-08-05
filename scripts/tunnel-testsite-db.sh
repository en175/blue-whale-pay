#!/usr/bin/env bash
# tunnel-testsite-db.sh —— 测试站数据库 SSH 隧道（唯一应急通道，ADR-0064 / IK65BP）。
#
# 原则：不直连、走隧道、用完断。公网 3306 已封禁；本脚本经 SSH 认证建立
# 本地端口转发，生命周期与终端会话绑定，Ctrl+C 或超时自动断开。
#
# 用法：
#   scripts/tunnel-testsite-db.sh [--local-port N] [--timeout MINUTES]
# 环境变量覆盖：BW_TESTSITE_HOST / BW_TESTSITE_USER / BW_TESTSITE_DB_PORT

set -euo pipefail

HOST="${BW_TESTSITE_HOST:-115.190.244.91}"
USER_NAME="${BW_TESTSITE_USER:-root}"
DB_PORT="${BW_TESTSITE_DB_PORT:-3306}"
LOCAL_PORT=13306
TIMEOUT_MINUTES=0

usage() {
  cat >&2 <<USAGE
用法: scripts/tunnel-testsite-db.sh [--local-port N] [--timeout MINUTES]

  --local-port N     本地转发端口（默认 13306）
  --timeout MINUTES  自动断开时间（默认 0 = 前台手动 Ctrl+C 断开）

建立后本地连 127.0.0.1:<local-port> 即测试站 MySQL；仅供只读排查（ADR-0064）。
USAGE
  exit 2
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --local-port)
      [ "$#" -ge 2 ] || usage
      LOCAL_PORT="$2"; shift 2 ;;
    --timeout)
      [ "$#" -ge 2 ] || usage
      TIMEOUT_MINUTES="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "❌ 未知参数：$1" >&2; usage ;;
  esac
done

case "$LOCAL_PORT" in
  ''|*[!0-9]*) echo "❌ --local-port 必须是正整数：$LOCAL_PORT" >&2; exit 2 ;;
esac
if [ "$LOCAL_PORT" -lt 1024 ] || [ "$LOCAL_PORT" -gt 65535 ]; then
  echo "❌ --local-port 须在 1024-65535：$LOCAL_PORT" >&2; exit 2
fi
case "$TIMEOUT_MINUTES" in
  ''|*[!0-9]*) echo "❌ --timeout 必须是非负整数（分钟）：$TIMEOUT_MINUTES" >&2; exit 2 ;;
esac

command -v ssh >/dev/null 2>&1 || { echo "❌ 未找到 ssh 命令" >&2; exit 1; }

# Fail closed：本地端口已被占用则拒绝，避免误连到别的进程。
if (exec 3<>"/dev/tcp/127.0.0.1/$LOCAL_PORT") 2>/dev/null; then
  exec 3>&- 3<&- || true
  echo "❌ 本地端口 $LOCAL_PORT 已被占用；换一个：--local-port <N>" >&2
  exit 1
fi

echo "🔗 隧道：127.0.0.1:$LOCAL_PORT -> $USER_NAME@$HOST:$DB_PORT"
echo "   连接示例：mysql -h 127.0.0.1 -P $LOCAL_PORT -u <只读账号> -p blue_whale"
echo "   纪律：只读排查；用完 Ctrl+C 断开（ADR-0064）。"

ssh_args=(-N -o ExitOnForwardFailure=yes -o ServerAliveInterval=15 -o ServerAliveCountMax=3
  -L "$LOCAL_PORT:127.0.0.1:$DB_PORT" "$USER_NAME@$HOST")

if [ "$TIMEOUT_MINUTES" -gt 0 ]; then
  ssh "${ssh_args[@]}" &
  ssh_pid=$!
  trap 'kill "$ssh_pid" 2>/dev/null || true' EXIT INT TERM
  echo "   ⏱  $TIMEOUT_MINUTES 分钟后自动断开。"
  sleep "$((TIMEOUT_MINUTES * 60))" &
  sleep_pid=$!
  wait -n "$ssh_pid" "$sleep_pid" 2>/dev/null || true
  kill "$ssh_pid" "$sleep_pid" 2>/dev/null || true
  echo "✅ 隧道已断开。"
else
  exec ssh "${ssh_args[@]}"
fi
