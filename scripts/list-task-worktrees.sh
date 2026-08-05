#!/usr/bin/env bash
# Read-only report for managed task worktrees.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/worktree-paths.sh
source "$ROOT/scripts/lib/worktree-paths.sh"
WORKTREE_BASE="$(worktree_paths_resolve_base "$ROOT")"

if [ ! -d "$WORKTREE_BASE" ]; then
  echo "未发现任务 worktree 目录：$WORKTREE_BASE"
  exit 0
fi

git -C "$ROOT" fetch origin >/dev/null 2>&1 || true

found=0
printf '%s\n' "任务 worktree 巡检（只读）：$WORKTREE_BASE"
printf '%s\n' ""

for path in "$WORKTREE_BASE"/*; do
  [ -d "$path" ] || continue
  if ! git -C "$path" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    continue
  fi

  found=1
  branch="$(git -C "$path" symbolic-ref --short HEAD 2>/dev/null || echo "detached")"
  dirty="clean"
  [ -n "$(git -C "$path" status --porcelain)" ] && dirty="dirty"

  merged="unknown"
  if git -C "$path" rev-parse --verify --quiet refs/remotes/origin/master >/dev/null 2>&1; then
    if git -C "$path" merge-base --is-ancestor HEAD origin/master 2>/dev/null; then
      merged="merged"
    else
      merged="not-merged"
    fi
  fi

  remote="absent"
  if [ "$branch" != "detached" ] && git -C "$path" ls-remote --exit-code --heads origin "$branch" >/dev/null 2>&1; then
    remote="present"
  fi

  printf '路径: %s\n' "$path"
  printf '  分支: %s\n' "$branch"
  printf '  工作区: %s\n' "$dirty"
  printf '  是否进 origin/master: %s\n' "$merged"
  printf '  远程源分支: %s\n' "$remote"
  if [ "$dirty" = "clean" ] && [ "$merged" = "merged" ]; then
    printf '  建议: 可进入该 worktree 执行 scripts/cleanup-task-worktree.sh\n'
  elif [ "$dirty" = "dirty" ]; then
    printf '  建议: 先处理未提交改动\n'
  else
    printf '  建议: 保留，等待 PR 合并或继续处理审查反馈\n'
  fi
  printf '\n'
done

if [ "$found" -eq 0 ]; then
  echo "未发现由本项目管理的任务 worktree。"
fi
