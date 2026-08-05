#!/bin/bash
# SessionStart hook: 注入 superpowers 的 using-superpowers 引导（团队共享版）。
#
# 本仓把 superpowers 作为入库共享技能（权威源 .superpowers/）。
# 官方插件版（.superpowers/hooks/session-start）按环境变量选择 JSON 输出格式，
# 适配插件协议。本仓的 SessionStart 钩子约定是平文注入（见 cbm-session-reminder.sh），
# 因此本包装复用官方的"读 using-superpowers 全文 + 组装引导文本"逻辑，
# 改为输出平文，与本仓现有 SessionStart 钩子风格一致。
#
# 注入内容服从 CLAUDE.md（团队 Agent 规则唯一权威源）。

set -euo pipefail

# 定位仓库根（支持主 checkout 与 task worktree）。
ROOT="$(git rev-parse --show-toplevel 2>/dev/null && true)"
if [ -z "$ROOT" ]; then
  # 不在 git 仓库内（极少见），按脚本相对位置兜底。
  SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
  ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
fi

USING_SKILL="$ROOT/.superpowers/skills/using-superpowers/SKILL.md"

if [ ! -f "$USING_SKILL" ]; then
  echo "superpowers: using-superpowers 引导缺失（$USING_SKILL 不存在），跳过注入。" >&2
  exit 0
fi

cat <<HEADER
<EXTREMELY_IMPORTANT>
You have superpowers.

Below is the full content of your 'superpowers:using-superpowers' skill — your introduction to using skills. For all other superpowers skills, use the Skill tool or read them under .superpowers/skills/ (.claude/skills/ 与 .zcode/skills/ 为同步副本).

服从 CLAUDE.md：CLAUDE.md 是本仓库团队 Agent 规则的唯一权威源。superpowers 技能为可选方法论，不替代 CLAUDE.md 的 git/issue 工作流硬规则。特别地，using-git-worktrees 的 declared preference = scripts/start-task-worktree.sh（见 CLAUDE.md 红线 #4）。

---

HEADER

cat "$USING_SKILL"

cat <<FOOTER

---

(以上为 superpowers:using-superpowers 引导，由 .claude/hooks/superpowers-session-start.sh 注入。)
</EXTREMELY_IMPORTANT>
FOOTER

exit 0
