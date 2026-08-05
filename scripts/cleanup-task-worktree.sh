#!/usr/bin/env bash
# Remove the current task worktree after its branch is merged into origin/master.

set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
# Git Bash on Windows：git rev-parse 返回 `D:/...`（大写盘符），pwd 返回 `/d/...`（小写 posix）。
# case 比较大小写敏感会误判，统一走 pwd 风格。
ROOT="$(cd "$ROOT" && pwd)"
# shellcheck source=lib/worktree-paths.sh
source "$ROOT/scripts/lib/worktree-paths.sh"
WORKTREE_BASE="$(worktree_paths_resolve_base "$ROOT")"

fail() {
  echo "❌ cleanup-task-worktree: $*" >&2
  exit 1
}

case "$ROOT" in
  "$WORKTREE_BASE"/*) ;;
  *) fail "请在 $WORKTREE_BASE 下的任务 worktree 内执行。" ;;
esac

branch="$(git -C "$ROOT" symbolic-ref --short HEAD 2>/dev/null || true)"
case "$branch" in
  feature/*|fix/*|hotfix/*|docs/*|chore/*) ;;
  "") fail "当前不是分支状态。" ;;
  *) fail "当前分支不是工单分支：$branch" ;;
esac

if [ -n "$(git -C "$ROOT" status --porcelain)" ]; then
  git -C "$ROOT" status --short >&2
  fail "工作区不干净，不能清理。"
fi

git -C "$ROOT" fetch origin

if ! git -C "$ROOT" merge-base --is-ancestor HEAD origin/master; then
  fail "当前分支尚未被 origin/master 包含。请等待 PR 合并，或继续处理审查反馈。"
fi

# 主 checkout = 不在 $WORKTREE_BASE 下的那个 worktree。
# 不依赖主 checkout 当前的分支状态（它可能 detached 或临时切到别的分支）；
# 用 substr 整行截取路径，兼容含空格的路径（awk 按字段切会把空格后的路径截断）。
main_root="$(git -C "$ROOT" worktree list --porcelain | awk -v base="$WORKTREE_BASE/" '
  /^worktree / {
    path = substr($0, 10)
    if (substr(path, 1, length(base)) != base) { print path; exit }
  }
')"

[ -n "$main_root" ] || fail "找不到主 checkout（不在 $WORKTREE_BASE 下的 worktree），不能安全删除。"

cd "$main_root"

# 删除顺序（IK00BP 修复）：先 ls-remote 探活 + 删远程（网络操作），确认后再删本地
# （worktree + ref）。不变式：网络操作必须最先且在本地删除之前。ls-remote --exit-code 三态：
#   exit 0=远程存在 → push --delete；exit 2=远程不存在 → 幂等跳过；
#   其他（1/128 等：网络瞬断/认证失败）→ 远程状态未知，报错且不动本地（worktree+ref+远程全未变），可安全重试。
# 旧逻辑先删 worktree+本地 ref 再探活，网络瞬断返回非0非2被当「不存在」跳过删远程，
# 留下「本地删、远程留」终态且 worktree 已无，重跑入口校验卡死。worktree remove / update-ref
# 为本地操作放最后——若它们失败，远程已正确清理，无残留源分支，仅需本地重试或手动 prune。
probe_rc=0
git ls-remote --exit-code --heads origin "$branch" >/dev/null 2>&1 || probe_rc=$?
if [ "$probe_rc" = 0 ]; then
  git push origin --delete "$branch"
elif [ "$probe_rc" != 2 ]; then
  fail "ls-remote 探活失败（exit ${probe_rc}），远程状态未知，未删本地分支：${branch}。网络恢复后重试即可。"
fi

# 远程已处理：删 worktree（本地，可重建）。
git worktree remove "$ROOT"

# 本地 master 可能是用户本地集成区，未必包含 origin/master。
# 前面已经证明任务分支 HEAD 被 origin/master 包含，因此直接删除本地 ref 是安全清理。
git update-ref -d "refs/heads/$branch"

git fetch --prune

echo "✅ 已清理任务 worktree 和分支：$branch"
