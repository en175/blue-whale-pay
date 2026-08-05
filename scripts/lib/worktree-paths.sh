#!/usr/bin/env bash
# Shared path derivation for worktree scripts.
#
# 只管「由 ROOT 算 WORKTREE_BASE」这一段。ROOT 本身有两种有意为之的推导语义，
# 必须保留在各调用脚本，不可合并进本 lib：
#   - 主 checkout 脚本用 BASH_SOURCE（脚本在主 checkout scripts/，运行时不在 worktree 上下文）
#   - worktree 脚本用 git rev-parse --show-toplevel（取当前 worktree 根）
# 若把 ROOT 也统一，worktree 脚本会错误拿到主 checkout 的根。
#
# 用法：WORKTREE_BASE="$(worktree_paths_resolve_base "$ROOT")"

worktree_paths_resolve_base() {
  local root="$1"
  local parent
  parent="$(cd "$root/.." && pwd)"
  if [ "$(basename "$parent")" = "blue-whale-worktrees" ]; then
    printf '%s' "$parent"
  else
    printf '%s' "$parent/blue-whale-worktrees"
  fi
}
