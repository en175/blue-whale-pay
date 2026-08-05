#!/usr/bin/env bash
# deploy-blue-whale-api 公共配置。source 自 build/push/remote-build/restart/deploy。
# 环境变量覆盖：DEPLOY_KEY / DEPLOY_HOST / DEPLOY_USER / REMOTE_DIR / API_PORT / MYSQL_DSN / REDIS_DSN / BUN

DEPLOY_KEY="${DEPLOY_KEY:-/Users/apple/Downloads/weitian.pem}"
DEPLOY_HOST="${DEPLOY_HOST:-115.190.244.91}"
DEPLOY_USER="${DEPLOY_USER:-root}"
REMOTE_DIR="${REMOTE_DIR:-/opt/blue-whale-api}"
API_PORT="${API_PORT:-3001}"                 # 宿主端口（避 blue_whale_web 3000 撞车）
CONTAINER="blue-whale-api"
IMAGE="blue-whale-api:latest"
BIN_NAME="new-api"                           # 容器内二进制名

# new-api 连接：容器经公网 IP 回连宿主 mysql8/redis
MYSQL_DSN="${MYSQL_DSN:-root:weitian1024@tcp($DEPLOY_HOST:3306)/new-api?parseTime=true}"
REDIS_DSN="${REDIS_DSN:-redis://:weitian1024@$DEPLOY_HOST:6379/1}"   # db1，与 Java db0 隔离

# 国内 docker mirror（失效自动 fallback）；apk 包源
MIRRORS=(docker.m.daocloud.io docker.1ms.run dockerproxy.cn dockerhub.icu)
ALPINE_PAK_MIRROR="${ALPINE_PAK_MIRROR:-mirrors.aliyun.com}"

# 本地 bun（npm 本地装到 ~/bun-install，不 sudo）
BUN="${BUN:-$HOME/bun-install/node_modules/.bin/bun}"

ensure_key() {
  [ -f "$DEPLOY_KEY" ] || { echo "密钥不存在: $DEPLOY_KEY" >&2; exit 1; }
  chmod 600 "$DEPLOY_KEY" 2>/dev/null || true
}

SSH_OPTS=(-i "$DEPLOY_KEY" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10)
SSH=(ssh "${SSH_OPTS[@]}" "$DEPLOY_USER@$DEPLOY_HOST")
SCP=(scp -q "${SSH_OPTS[@]}")
