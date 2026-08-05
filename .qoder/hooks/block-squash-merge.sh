#!/usr/bin/env bash
# Claude Code PreToolUse hook — 拦截 AI 用 squash/rebase 合并 PR
#
# 拦截：mcp__gitee-ent__merge_enterprise_pull 的 merge_method 为 squash / rebase
# 放行：merge（或缺省，Gitee 默认 merge）
#
# 注意：本脚本已不在三端配置（.claude/settings.json / .codex/hooks.json /
# .zcode/config.json）注册。squash/rebase 检查的**生产路径**已迁移到
# confirm-release-action.sh（在凭证校验前判定），以消除多 hook 执行顺序
# 不确定导致的纠正信号误导。
#
# 本脚本保留为独立可测单元（scripts/test-hooks.sh 仍覆盖），且与
# confirm-release-action.sh 共用 lib/merge-method-check.sh 的判定逻辑，
# 两者不会因单边修改而漂移。
#
# 退出码 2 = 阻断 Claude 执行该工具调用。

INPUT=$(cat)
HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"

# shellcheck source=lib/merge-method-check.sh
. "$HOOK_DIR/lib/merge-method-check.sh"

# 提取 tool_input.merge_method（grep 取值行，去引号）；jq 不可用时的零依赖兜底
METHOD=$(printf '%s' "$INPUT" | grep -o '"merge_method"[[:space:]]*:[[:space:]]*"[^"]*"' | head -n1 | sed -E 's/.*"merge_method"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/')

# 缺省（未传 merge_method，Gitee 默认 merge）→ 放行
[ -z "$METHOD" ] && exit 0

# squash/rebase → 阻断（消息由共享函数输出）；merge/其他 → return 继续到 exit 0
check_merge_method_and_block "$METHOD"
exit 0
