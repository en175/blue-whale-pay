#!/usr/bin/env bash
# 一键全流程：build → push → remote-build → restart。
# 用法: deploy.sh   （new-api 单服务，无参数）
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"
ensure_key

echo "==== 1/4 build（bun build 前端 + go 交叉编译）===="
"$SCRIPT_DIR/build.sh"
echo "==== 2/4 push（scp + 远程生成 .env）===="
"$SCRIPT_DIR/push.sh"
echo "==== 3/4 remote-build（mirror fallback + docker build）===="
"$SCRIPT_DIR/remote-build.sh"
echo "==== 4/4 restart（prev 备份 + 重建 + 验证）===="
"$SCRIPT_DIR/restart.sh"

echo ""
echo "✓✓ 部署完成  http://$DEPLOY_HOST:$API_PORT（云安全组放行 $API_PORT 后外部可达）"
