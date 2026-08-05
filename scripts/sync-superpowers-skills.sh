#!/usr/bin/env bash
# Sync superpowers skills from the authoritative source (.superpowers/skills/)
# to the two harness runtime discovery dirs: .claude/skills/ and .zcode/skills/.
#
# Only the 14 superpowers skill names (whitelist) are touched — existing
# mattpocock skills in .claude/skills/ are never deleted or overwritten.
#
# Codex is intentionally NOT synced: it uses each user's local official plugin
# (~/.codex/plugins/cache/claude-plugins-official/superpowers), not an in-repo copy.
#
# Usage:
#   scripts/sync-superpowers-skills.sh           # sync for real
#   scripts/sync-superpowers-skills.sh --dry-run # show what would change, no writes

set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
ROOT="$(cd "$ROOT" && pwd)"

SRC="$ROOT/.superpowers/skills"
TARGETS=("$ROOT/.claude/skills" "$ROOT/.zcode/skills")

# Whitelist: the 14 superpowers skill dir names. Anything else in TARGETS is
# left untouched (protects mattpocock skills like tdd, grilling, etc.).
SKILLS=(
  brainstorming
  dispatching-parallel-agents
  executing-plans
  finishing-a-development-branch
  receiving-code-review
  requesting-code-review
  subagent-driven-development
  systematic-debugging
  test-driven-development
  using-git-worktrees
  using-superpowers
  verification-before-completion
  writing-plans
  writing-skills
)

DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

fail() { echo "❌ sync-superpowers-skills: $*" >&2; exit 1; }

# --- preflight ---------------------------------------------------------------
[ -d "$SRC" ] || fail ".superpowers/skills/ 不存在（权威源缺失）。"
[ -f "$ROOT/.superpowers/VERSION" ] || fail ".superpowers/VERSION 不存在。"

# Warn if any whitelisted skill is missing from the source.
missing=0
for s in "${SKILLS[@]}"; do
  if [ ! -f "$SRC/$s/SKILL.md" ]; then
    echo "❌ 权威源缺少 skill: $s ($SRC/$s/SKILL.md)" >&2
    missing=1
  fi
done
[ "$missing" -eq 0 ] || fail "权威源不完整，先修复 .superpowers/skills/ 再同步。"

VERSION="$(grep -E '^superpowers:' "$ROOT/.superpowers/VERSION" | awk '{print $2}')"
echo "ℹ️  权威源版本：superpowers ${VERSION:-unknown}"
echo "ℹ️  目标端：${TARGETS[*]}"
[ "$DRY_RUN" -eq 1 ] && echo "ℹ️  DRY-RUN：仅报告，不写入。"
echo ""

# --- sync --------------------------------------------------------------------
sync_one() {
  local target_dir="$1"
  mkdir -p "$target_dir"
  local sk
  for sk in "${SKILLS[@]}"; do
    if [ -d "$target_dir/$sk" ]; then
      if diff -rq "$SRC/$sk" "$target_dir/$sk" >/dev/null 2>&1; then
        printf '   = %s（已一致）\n' "$sk"
        continue
      fi
    fi
    if [ "$DRY_RUN" -eq 1 ]; then
      printf '   ~ %s（将更新 %s/%s）\n' "$sk" "$target_dir" "$sk"
    else
      rm -rf "$target_dir/$sk"
      cp -R "$SRC/$sk" "$target_dir/$sk"
      printf '   ✓ %s → %s/%s\n' "$sk" "$target_dir" "$sk"
    fi
  done
}

for t in "${TARGETS[@]}"; do
  echo "▶ 同步到 ${t#$ROOT/}"
  sync_one "$t"
  echo ""
done

echo "✅ 同步完成（${#SKILLS[@]} 个 skill，2 个目标端）。"
echo "   下一步：git add 并 commit（走 scripts/commit-task-for-review.sh）。"
