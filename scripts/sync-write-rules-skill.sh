#!/usr/bin/env bash
# Sync the project-level write-rules skill from its authoritative in-repo source
# (.claude/skills/write-rules/) to the other three harness skill dirs.
#
# write-rules is NOT a superpowers skill, so sync-superpowers-skills.sh does not
# touch it. This script is its standalone four-platform sync.
#
# Authority: .claude/skills/write-rules/SKILL.md (in-repo, tracked).
# Targets:
#   .zcode/skills/write-rules/      — tracked (team-shared, mirrors .claude/)
#   .kimi-code/skills/write-rules/  — local only (gitignored; per-user)
#   ~/.codex/skills/write-rules/    — local only (user home; per-user)
#
# Codex/Kimi targets stay out of the repo on purpose: the project's existing
# design (see sync-superpowers-skills.sh) keeps only .claude/ and .zcode/ skills
# in git; Codex/Kimi skills are per-user local copies.
#
# Usage:
#   scripts/sync-write-rules-skill.sh           # sync for real
#   scripts/sync-write-rules-skill.sh --dry-run # show what would change, no writes

set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
ROOT="$(cd "$ROOT" && pwd)"

SRC="$ROOT/.claude/skills/write-rules/SKILL.md"
TRACKED_TARGET="$ROOT/.zcode/skills/write-rules/SKILL.md"
LOCAL_TARGETS=("$ROOT/.kimi-code/skills/write-rules/SKILL.md" "$HOME/.codex/skills/write-rules/SKILL.md")

DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

fail() { echo "❌ sync-write-rules-skill: $*" >&2; exit 1; }

[ -f "$SRC" ] || fail "权威源缺失：${SRC}（.claude/skills/write-rules/SKILL.md 不存在）"

echo "ℹ️  权威源：${SRC#"$ROOT"/}"
echo "ℹ️  进仓目标：.zcode/skills/write-rules/"
echo "ℹ️  本地目标：.kimi-code/skills/write-rules/ + ~/.codex/skills/write-rules/"
[ "$DRY_RUN" -eq 1 ] && echo "ℹ️  DRY-RUN：仅报告，不写入。"
echo ""

sync_to() {
  local dest="$1"
  local label="$2"
  if [ -f "$dest" ] && diff -q "$SRC" "$dest" >/dev/null 2>&1; then
    printf '   = %s（已一致）\n' "$label"
    return
  fi
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '   ~ %s（将更新）\n' "$label"
  else
    mkdir -p "$(dirname "$dest")"
    cp "$SRC" "$dest"
    printf '   ✓ %s\n' "$label"
  fi
}

echo "▶ 进仓目标（团队共享，变化需 commit）"
sync_to "$TRACKED_TARGET" ".zcode/skills/write-rules"
echo ""

echo "▶ 本地目标（个人，不进仓）"
sync_to "${LOCAL_TARGETS[0]}" ".kimi-code/skills/write-rules"
sync_to "${LOCAL_TARGETS[1]}" "~/.codex/skills/write-rules"
echo ""

echo "✅ 同步完成。"
echo "   .zcode 端若变化：git add 并走 scripts/commit-task-for-review.sh。"
echo "   .kimi-code / ~/.codex 为本地副本，不入库。"
