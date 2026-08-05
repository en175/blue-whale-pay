#!/usr/bin/env bash
# scp 二进制 + Dockerfile + compose 到远程；远程生成 .env（强随机 SESSION_SECRET，不本地落盘）。
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ensure_key

BIN="$SKILL_DIR/.build/$BIN_NAME"
[ -f "$BIN" ] || { echo "✗ 二进制不存在，先跑 build.sh" >&2; exit 1; }

"${SSH[@]}" "mkdir -p $REMOTE_DIR"

echo "▶ scp 二进制（$(du -h "$BIN" | cut -f1)）"
"${SCP[@]}" "$BIN" "$DEPLOY_USER@$DEPLOY_HOST:$REMOTE_DIR/$BIN_NAME"

echo "▶ scp Dockerfile + compose"
"${SCP[@]}" "$SKILL_DIR/docker/Dockerfile" "$DEPLOY_USER@$DEPLOY_HOST:$REMOTE_DIR/Dockerfile"
"${SCP[@]}" "$SKILL_DIR/docker/docker-compose.yml" "$DEPLOY_USER@$DEPLOY_HOST:$REMOTE_DIR/docker-compose.yml"

# 远程生成 .env：SESSION_SECRET 远程 openssl 生成（不本地落盘，避免 ssh 参数携带）
echo "▶ 远程生成 .env（SESSION_SECRET = openssl rand 远程生成）"
"${SSH[@]}" "SECRET=\$(openssl rand -hex 32) && cat > $REMOTE_DIR/.env <<EOF
SQL_DSN=$MYSQL_DSN
REDIS_CONN_STRING=$REDIS_DSN
SESSION_SECRET=\$SECRET
TZ=Asia/Shanghai
EOF
chmod 600 $REMOTE_DIR/.env && echo '  → .env 写入 + chmod 600'"

echo "✓ push 完成"
