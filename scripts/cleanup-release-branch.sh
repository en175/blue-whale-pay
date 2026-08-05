#!/usr/bin/env bash
# Clean up a merged release-wrapper branch on the main checkout after explicit user authorization.
set -euo pipefail

AUTHORIZED=0
BRANCH=""

usage() {
  cat >&2 <<EOF
用法: scripts/cleanup-release-branch.sh --user-authorized <branch>

在主 checkout 的本地 master 上，清理已合并进 origin/master 的发布包装分支：
删本地分支 + 删远程源分支 + git fetch --prune。
EOF
  exit 2
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --user-authorized) AUTHORIZED=1; shift ;;
    -h|--help) usage ;;
    -*) echo "❌ cleanup-release-branch: 不支持的参数：$1" >&2; usage ;;
    *) [ -z "$BRANCH" ] || usage; BRANCH="$1"; shift ;;
  esac
done

fail() { echo "❌ cleanup-release-branch: $*" >&2; exit 1; }

[ "$AUTHORIZED" = 1 ] || fail "缺少 --user-authorized。必须先获得用户明确授权清理发布包装分支。"
[ -n "$BRANCH" ] || fail "缺少发布包装分支名。"

# ROOT 用 BASH_SOURCE 而非 git rev-parse --show-toplevel：本脚本是主 checkout 脚本
# （lib/worktree-paths.sh 注释约定），运行时可能 cwd 在任意处；BASH_SOURCE 派生的 ROOT
# 稳定指向主 checkout scripts/ 的父目录，不依赖 worktree 上下文。
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/worktree-paths.sh
source "$ROOT/scripts/lib/worktree-paths.sh"
WORKTREE_BASE="$(worktree_paths_resolve_base "$ROOT")"

# 必须在主 checkout（非 worktree）；worktree 形态走 cleanup-task-worktree.sh
case "$ROOT" in "$WORKTREE_BASE"/*) fail "请在主 checkout 执行，不要在任务 worktree 内清理：$ROOT" ;; esac

# 当前必须在本地 master
current="$(git -C "$ROOT" symbolic-ref --short HEAD 2>/dev/null || true)"
[ "$current" = "master" ] || fail "当前分支是 ${current:-detached HEAD}，请先切回本地 master。"

# 工作区必须干净
if [ -n "$(git -C "$ROOT" status --porcelain)" ]; then
  git -C "$ROOT" status --short >&2
  fail "工作区不干净，不能清理。"
fi

# 目标分支白名单（与 branch-naming.md / ADR-0004 同源）
case "$BRANCH" in feature/*|fix/*|hotfix/*|docs/*|chore/*) ;; *) fail "分支必须使用白名单前缀：feature/ fix/ hotfix/ docs/ chore/" ;; esac

# 本地分支必须存在
git -C "$ROOT" show-ref --verify --quiet "refs/heads/$BRANCH" || fail "本地分支不存在：$BRANCH"

# 确保 origin/master 最新，再校验已合并
git -C "$ROOT" fetch origin master
git -C "$ROOT" merge-base --is-ancestor "$BRANCH" origin/master \
  || fail "$BRANCH 尚未被 origin/master 包含。请等待 PR 合并后再清理。"

# 删除顺序（IK00BP 修复）：先 ls-remote 探活 + 删远程，确认后再删本地 ref。
# 不变式：删本地必须在远程状态确定之后。ls-remote --exit-code 三态：
#   exit 0=远程存在 → push --delete + 删本地
#   exit 2=远程不存在 → 幂等跳过，仅删本地（如已被网页删除）
#   其他（1/128 等：网络瞬断/认证失败）→ 远程状态未知，报错且不删本地
# 旧逻辑先 update-ref -d 再探活，网络瞬断返回非0非2被当「不存在」跳过删远程，
# 留下「本地删、远程留」不一致终态，重跑因本地已无分支而卡死。
# update-ref -d 直接删 ref（本地 master 可能落后 origin/master，故不用 branch -d——
# 其「已合入当前 HEAD」判定在集成区落后时会误拒；ancestor 已证明分支在 origin/master 内，删 ref 安全）。
probe_rc=0
git -C "$ROOT" ls-remote --exit-code --heads origin "$BRANCH" >/dev/null 2>&1 || probe_rc=$?
if [ "$probe_rc" = 0 ]; then
  git -C "$ROOT" push origin --delete "$BRANCH"
  git -C "$ROOT" update-ref -d "refs/heads/$BRANCH"
elif [ "$probe_rc" = 2 ]; then
  git -C "$ROOT" update-ref -d "refs/heads/$BRANCH"
else
  fail "ls-remote 探活失败（exit ${probe_rc}），远程状态未知，未删本地分支：${BRANCH}。网络恢复后重试即可。"
fi
git -C "$ROOT" fetch --prune

echo "✅ 已清理发布包装分支：$BRANCH"
