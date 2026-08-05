#!/usr/bin/env bash
# Sync the project-level codex skill from its authoritative in-repo source
# (.claude/skills/codex/SKILL.md) to the other three harness skill dirs.
#
# Authority: .claude/skills/codex/SKILL.md (in-repo, tracked).
# Targets:
#   .zcode/skills/codex/SKILL.md      — tracked (team-shared, mirrors .claude/)
#   .kimi-code/skills/codex/SKILL.md  — local only (gitignored; per-user)
#   ~/.codex/skills/codex/SKILL.md    — local only (user home; per-user)
#
# Same pattern as sync-write-rules-skill.sh: only .claude/ and .zcode/ skills
# are tracked; Codex/Kimi skills are per-user local copies.
#
# Usage:
#   scripts/sync-codex-skill.sh           # sync for real
#   scripts/sync-codex-skill.sh --dry-run # show what would change, no writes

set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
ROOT="$(cd "$ROOT" && pwd)"

SRC="$ROOT/.claude/skills/codex/SKILL.md"
TRACKED_TARGET="$ROOT/.zcode/skills/codex/SKILL.md"
LOCAL_TARGETS=("$ROOT/.kimi-code/skills/codex/SKILL.md" "$HOME/.codex/skills/codex/SKILL.md")

DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

fail() { echo "❌ sync-codex-skill: $*" >&2; exit 1; }

[ -f "$SRC" ] || fail "权威源缺失：${SRC#"$ROOT"/}（.claude/skills/codex/SKILL.md 不存在）"

echo "ℹ️  权威源：${SRC#"$ROOT"/}"
echo "ℹ️  进仓目标：.zcode/skills/codex/"
echo "ℹ️  本地目标：.kimi-code/skills/codex/ + ~/.codex/skills/codex/"
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
sync_to "$TRACKED_TARGET" ".zcode/skills/codex"
echo ""

echo "▶ 本地目标（个人，不进仓）"
sync_to "${LOCAL_TARGETS[0]}" ".kimi-code/skills/codex"
sync_to "${LOCAL_TARGETS[1]}" "~/.codex/skills/codex"
echo ""

echo "✅ 同步完成。"
echo "   .zcode 端若变化：git add 并走 scripts/commit-task-for-review.sh。"
echo "   .kimi-code / ~/.codex 为本地副本，不入库。"
