#!/usr/bin/env bash
# 远程：mirror fallback pull alpine:3.20 + tag + docker compose build。
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"
ensure_key

echo "▶ 确保 alpine:3.20（mirror fallback）"
# 远程块：已有则跳过；无则逐 mirror 试 pull+tag（MIRRORS 本地展开传入）
"${SSH[@]}" "set -e
if docker image inspect alpine:3.20 >/dev/null 2>&1; then
  echo '  alpine:3.20 已存在'
else
  pulled=0
  for m in ${MIRRORS[*]}; do
    echo \"  试 \$m/library/alpine:3.20\"
    if timeout 60 docker pull \"\$m/library/alpine:3.20\" >/tmp/_alpine_pull.log 2>&1; then
      docker tag \"\$m/library/alpine:3.20\" alpine:3.20 && pulled=1 && echo \"  ✓ \$m\" && break
    fi
  done
  if [ \"\$pulled\" -eq 0 ]; then
    echo '✗ 所有 mirror 拉不到 alpine:3.20；给远程 /etc/docker/daemon.json 配 registry-mirrors 后 systemctl restart docker' >&2
    cat /tmp/_alpine_pull.log >&2 || true
    exit 1
  fi
fi"

echo "▶ 远程 docker compose build"
"${SSH[@]}" "cd $REMOTE_DIR && docker compose build" \
  || { echo "✗ 远程 build 失败（Dockerfile apk 已配 $ALPINE_PAK_MIRROR 源；若仍失败查 build 输出）" >&2; exit 1; }
echo "✓ remote build 完成"
