#!/usr/bin/env bash
# Build or refresh Graphify output for the current task worktree.

set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
# Git Bash on Windows：git rev-parse 返回 `D:/...`（大写盘符），pwd 返回 `/d/...`（小写 posix）。
# case 比较大小写敏感会误判，统一走 pwd 风格。
ROOT="$(cd "$ROOT" && pwd)"
# shellcheck source=lib/worktree-paths.sh
source "$ROOT/scripts/lib/worktree-paths.sh"
WORKTREE_BASE="$(worktree_paths_resolve_base "$ROOT")"

fail() {
  echo "❌ ensure-graphify-worktree: $*" >&2
  exit 1
}

case "$ROOT" in
  "$WORKTREE_BASE"/*) ;;
  *) fail "请在 $WORKTREE_BASE 下的任务 worktree 内执行。" ;;
esac

command -v graphify >/dev/null 2>&1 || fail "找不到 graphify 命令。请先安装/配置 Graphify。"

cd "$ROOT"
graphify update .

[ -f graphify-out/graph.json ] || fail "graphify update 完成后仍未发现 graphify-out/graph.json。"

echo "✅ 当前任务 worktree 的 Graphify 图谱已就绪：$ROOT/graphify-out/graph.json"
