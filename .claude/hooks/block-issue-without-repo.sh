#!/usr/bin/env bash
# Claude Code PreToolUse hook — 拦截 issue 不关联仓库，或子 issue 未继承父项归属
# 零依赖（grep/sed 解析 JSON，同 block-squash-merge.sh）。
#
# 拦截：
#   - create_enterprise_issue 根 issue 的 project_id 或 program_id 缺失 / 为空 / = 0
#   - create_enterprise_issue 的 description 缺失 / 为空（防错名参数被静默忽略建成空工单）
#   - create_enterprise_issue / update_enterprise_issue 带 parent_id，
#     但 project_id 或 program_id 缺失 / 为空 / = 0
#   - update_enterprise_issue 显式 project_id=0 或 program_id=0
# 放行：
#   - 根 issue 创建时 project_id 与 program_id 均非空且非 0
#   - 普通 update 不要求重复传 project_id/program_id
#   - 不校验 project_id/program_id 是否等于具体仓库/项目 ID（见 ADR-0007 D3、ADR-0014）
#
# 为什么：project_id / program_id 在 MCP schema 里是 number；Gitee 用 0 表示「无关联」。
# 不关联仓库的 issue（project_id=0）只出现在企业工作项列表，仓库 Issues 页看不到（见 ADR-0007）。
# 不归属项目的根 issue（program_id=0）游离于企业「项目管理」之外（见 ADR-0014）。
# 子工作项如果只传 parent_id 而不继承 project_id/program_id，也会出现在企业工作台
# 的父项下，但仓库 Issues/MCP 仓库过滤查不到（见 ADR-0008）。
#
# 配套：settings.json PreToolUse matcher = mcp__gitee-ent__create_enterprise_issue /
#      mcp__gitee-ent__update_enterprise_issue。
# 退出码 2 = 阻断 Claude 执行该工具调用。
# 同步：.qoder/hooks/ 有本文件的手动同步副本，任何改动必须双份同改。

INPUT=$(cat)
HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
AUDIT="$HOOK_DIR/lib/hook_audit.py"
HOOK_NAME="$(basename "$0")"
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"

extract_json_value() {
  key="$1"
  printf '%s' "$INPUT" \
    | grep -oE "\"${key}\"[[:space:]]*:[[:space:]]*(\"[^\"]*\"|[0-9]+)" \
    | head -n1 \
    | sed -E "s/.*\"${key}\"[[:space:]]*:[[:space:]]*\"?([^\"]*)\"?.*/\\1/"
}

TOOL_NAME=$(extract_json_value "tool_name")
PROJECT_ID=$(extract_json_value "project_id")
PROGRAM_ID=$(extract_json_value "program_id")
PARENT_ID=$(extract_json_value "parent_id")

IS_UPDATE=0
[ "$TOOL_NAME" = "mcp__gitee-ent__update_enterprise_issue" ] && IS_UPDATE=1

AUDIT_OPERATION="issue-create"
[ "$IS_UPDATE" -eq 1 ] && AUDIT_OPERATION="issue-update"

HAS_PARENT=0
[ -n "$PARENT_ID" ] && [ "$PARENT_ID" != "0" ] && HAS_PARENT=1

block() {
  reason="$1"
  printf '%s' "$INPUT" | python3 "$AUDIT" \
    --project-dir "$PROJECT_DIR" \
    --hook "$HOOK_NAME" \
    --operation "$AUDIT_OPERATION" \
    --exit-code 2 \
    --reason "blocked-policy" >/dev/null || true
  cat >&2 <<EOF
BLOCKED: ${reason}
  tool_name: ${TOOL_NAME:-（未知，按 create 规则处理）}
  parent_id: ${PARENT_ID:-（空）}
  project_id: ${PROJECT_ID:-（空）}
  program_id: ${PROGRAM_ID:-（空）}

本项目所有 issue 必须关联到 blue-whale-ai 仓库、且归属其项目：
- 不关联仓库的 issue（project_id=0）只出现在企业工作项列表，仓库 Issues 页看不到
- 不归属项目的根 issue（program_id=0）游离于企业「项目管理」之外
- 子工作项还必须继承父项的 project_id/program_id，否则父项页可见但仓库 Issues/MCP 仓库过滤查不到
- 团队按仓库 Issues / 项目管理查工单时会漏掉它（历史事件 IJZ5WA / IJZ74J-N / IK0FL6-7）

改法：
- 根 issue：创建时传 project_id（blue-whale-ai 仓库 ID，用 list_enterprise_repositories 查）和 program_id（项目 ID，用 list_programs 查）
- 子 issue：先 get 父 issue，创建/更新时传 parent_id=父项 id、project_id=父项 project_id、program_id=父项 program_id
- 发布后用 list_enterprise_issues(project_id, search=ident) 反查确认仓库可见

详见 docs/agents/issue-tracker.md「创建 issue」。
EOF
  exit 2
}

# 任何显式 project_id=0 都是无仓库关联，create/update 都拦。
if [ "$PROJECT_ID" = "0" ]; then
  block "issue 的 project_id 为 0（未关联仓库）。"
fi

# 任何显式 program_id=0 都是无项目归属，create/update 都拦（对称 project_id=0）。
if [ "$PROGRAM_ID" = "0" ]; then
  block "issue 的 program_id 为 0（未归属项目）。"
fi

# 子 issue：只要传 parent_id，就必须同时带有效 project_id/program_id。
if [ "$HAS_PARENT" -eq 1 ]; then
  if [ -z "$PROJECT_ID" ]; then
    block "子 issue 缺少 project_id，无法保证仓库 Issues 可见。"
  fi
  if [ -z "$PROGRAM_ID" ] || [ "$PROGRAM_ID" = "0" ]; then
    block "子 issue 缺少 program_id，未继承父项项目归属。"
  fi
fi

block_empty_description() {
  printf '%s' "$INPUT" | python3 "$AUDIT" \
    --project-dir "$PROJECT_DIR" \
    --hook "$HOOK_NAME" \
    --operation "$AUDIT_OPERATION" \
    --exit-code 2 \
    --reason "blocked-empty-description" >/dev/null || true
  cat >&2 <<'EOF'
BLOCKED: create_enterprise_issue 的 description 缺失或为空。

Gitee MCP 写工具对未知/错名参数静默忽略、不报错——把描述传到 body 等错名参数，
工单会建成空描述（历史事件 IK5THP）。

改法：
- 描述入参名是 description（不是 body），创建必传且非空
- 创建后 get_enterprise_issue_detail 回读确认 description 非空

详见 .claude/rules/issue-tracker.md「写操作回读验证」。
EOF
  exit 2
}

# create 根 issue：project_id 缺失 / 空字符串 / = 0 → 拦截。
# update 普通字段不要求重复传 project_id，避免拦状态/标签/标题更新。
if [ "$IS_UPDATE" -eq 0 ] && [ -z "$PROJECT_ID" ]; then
  block "创建根 issue 未关联仓库（project_id 缺失或为空）。"
fi

# create 根 issue：program_id 缺失 / 为空 / = 0 → 拦截（子 issue 在 parent 继承块已校验）。
# update 普通字段不要求重复传 program_id，避免拦状态/标签/标题更新。
if [ "$IS_UPDATE" -eq 0 ] && [ "$HAS_PARENT" -eq 0 ]; then
  if [ -z "$PROGRAM_ID" ] || [ "$PROGRAM_ID" = "0" ]; then
    block "创建根 issue 未归属项目（program_id 缺失或为 0）。"
  fi
fi

# create：description 缺失 / 为空 → 拦截。错名参数（如把描述传到 body）被 MCP 静默忽略，
# 会建成空描述工单（历史事件 IK5THP）。update 常只改状态/标签，不要求 description。
# 放在归属校验之后，让 project_id/program_id 的具体报错优先暴露。
if [ "$IS_UPDATE" -eq 0 ]; then
  DESCRIPTION=$(extract_json_value "description")
  if [ -z "$DESCRIPTION" ]; then
    block_empty_description
  fi
fi

printf '%s' "$INPUT" | python3 "$AUDIT" \
  --project-dir "$PROJECT_DIR" \
  --hook "$HOOK_NAME" \
  --operation "$AUDIT_OPERATION" \
  --exit-code 0 \
  --reason "allowed-policy" >/dev/null || true
exit 0
