#!/usr/bin/env bash
# Commit a task worktree diff as a reviewable, revertable checkpoint.
# worktree 工单分支上的 commit 是本地可逆动作（不碰 master、不 push、不 PR），
# 不属发布红线，无需用户授权门槛。用户确认环节落在 merge 本地 master 前。
#
# 两种模式：
#   首次提交（默认）：把已完成的子 issue diff 落成一个新 commit。
#   --amend：用户 review commit 后发现修订，覆盖最后 commit，维持「一个子 issue 一个 commit」粒度。
#            默认 --no-edit 保留原 commit message；-m 覆盖 message。仅在该分支已有首次提交后可用。

set -euo pipefail

MESSAGE=""
AMEND=0

usage() {
  cat >&2 <<EOF
用法:
  首次提交:        scripts/commit-task-for-review.sh -m "<commit-message>"
  review 后修订:   scripts/commit-task-for-review.sh --amend [-m "<new-message>"]

在任务 worktree 工单分支内提交已完成的子 issue diff，落成可 review、可 revert 的检查点。
--amend 覆盖该分支最后 commit（默认保留原 message，-m 覆盖）；仅在该分支已有首次提交后可用。
EOF
  exit 2
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    -m|--message)
      [ "$#" -ge 2 ] || usage
      MESSAGE="$2"
      shift 2
      ;;
    --amend)
      AMEND=1
      shift
      ;;
    -h|--help)
      usage
      ;;
    *)
      echo "❌ commit-task-for-review: 不支持的参数：$1" >&2
      usage
      ;;
  esac
done

fail() {
  echo "❌ commit-task-for-review: $*" >&2
  exit 1
}

ROOT="$(git rev-parse --show-toplevel)"
# Git Bash on Windows：git rev-parse 返回 `D:/...`（大写盘符），pwd 返回 `/d/...`（小写 posix）。
# case 比较大小写敏感会误判，统一走 pwd 风格。
ROOT="$(cd "$ROOT" && pwd)"
# shellcheck source=lib/worktree-paths.sh
source "$ROOT/scripts/lib/worktree-paths.sh"
WORKTREE_BASE="$(worktree_paths_resolve_base "$ROOT")"

case "$ROOT" in
  "$WORKTREE_BASE"/*) ;;
  *) fail "请在 $WORKTREE_BASE 下的任务 worktree 内执行，不能在用户本地 master 直接提交任务。" ;;
esac

branch="$(git -C "$ROOT" symbolic-ref --short HEAD 2>/dev/null || true)"
case "$branch" in
  feature/*|fix/*|hotfix/*|docs/*|chore/*) ;;
  "") fail "当前不是分支状态。" ;;
  *) fail "当前分支不是工单分支：$branch" ;;
esac

# worktree 私有 git dir 下存「已首次提交」标记：amend 前置校验 + 防误用首次模式追加第二 commit。
# 私有 git dir 仅属本 worktree（cleanup 删 worktree 时随之消失），不污染主 checkout 或并行 worktree。
FIRST_COMMIT_MARKER="$(git -C "$ROOT" rev-parse --absolute-git-dir)/agent-task-first-committed"

if [ "$AMEND" = 1 ]; then
  # amend 仅在工单分支已通过本入口首次提交后可用；否则会误改 worktree 基线（同步后的 master SHA）。
  [ -f "$FIRST_COMMIT_MARKER" ] || fail "当前工单分支尚无首次提交，--amend 会改写 worktree 基线。请先用 -m \"<message>\" 做首次提交。"
  git -C "$ROOT" add -A
  if [ -n "$MESSAGE" ]; then
    git -C "$ROOT" commit --amend -m "$MESSAGE"
  else
    git -C "$ROOT" commit --amend --no-edit
  fi
  echo "✅ 已修订任务验收分支的最后 commit：$branch"
else
  [ -n "$MESSAGE" ] || fail "缺少 commit message。请用 -m \"<message>\"。"
  if [ -f "$FIRST_COMMIT_MARKER" ]; then
    fail "当前工单分支已首次提交，追加新 commit 会破坏「一个子 issue 一个 commit」粒度。review 后修订请用 --amend。"
  fi
  if [ -z "$(git -C "$ROOT" status --porcelain)" ]; then
    fail "没有可提交的任务验收 diff。"
  fi
  git -C "$ROOT" add -A
  git -C "$ROOT" commit -m "$MESSAGE"
  : > "$FIRST_COMMIT_MARKER"
  echo "✅ 已提交任务验收分支：$branch"
fi

echo "下一步：用户确认后，可在本地 master 运行 scripts/merge-task-to-local-master.sh --user-authorized $branch"
