#!/usr/bin/env bash
# Claude Code / Codex / Kimi / ZCode PostToolUse — 工单状态流转提醒（仅观察，不阻断）
#
# 背景：Issue 状态机规则（.claude/rules/issue-tracker.md「任务状态与真实交付」）要求
# Agent 在关键节点核对实际交付与操作授权，但人工/模型都容易遗忘。本 hook 在触发点
# 打印提醒，钉住遗忘根因。红线 7：Hook 只纠偏、不推进状态机——本脚本始终
# exit 0，不自动改任何状态（脚本无 token，也改不了）。
#
# 触发（均 PostToolUse）：
#   1. Bash 成功执行 start-task-worktree 且带 --issue <ident>
#      → 提醒核对 PRD 评审、产品确认、版本、开发子任务创建、负责人及操作授权；worktree 成功不代表准入通过。
#   2. mcp__gitee-ent__create_enterprise_repo_pull 成功
#      → 提醒给关联工单打 ready-for-review 标签。
#   3. mcp__gitee-ent__merge_enterprise_pull 成功
#      → 提醒保留真实阶段；合并不等于测试、部署或验收，不自动完成工作项。
#
# 成功判定：kimi 的 PostToolUse 仅在工具成功时触发（失败走 PostToolUseFailure）；
# Claude/Codex 的 Post 对失败也可能触发，但提醒是纯提示，误提醒无害（Agent 会
# 自行判断入口是否真成功），故不做严格成功判定，保持零依赖。
#
# 退出码恒为 0：Post 阶段不能也不应阻断已执行的工具。
set -u

INPUT=$(cat)

extract_json_value() {
  key="$1"
  printf '%s' "$INPUT" \
    | grep -oE "\"${key}\"[[:space:]]*:[[:space:]]*(\"[^\"]*\"|[0-9]+)" \
    | head -n1 \
    | sed -E "s/.*\"${key}\"[[:space:]]*:[[:space:]]*\"?([^\"]*)\"?.*/\\1/"
}

TOOL_NAME=$(extract_json_value "tool_name")

case "$TOOL_NAME" in
  Bash)
    COMMAND=$(extract_json_value "command")
    # 只关心 worktree 入口命令；其余 Bash 静默。
    case "$COMMAND" in
      *start-task-worktree*)
        ;;
      *)
        exit 0
        ;;
    esac
    # 提取 --issue 的工单号；--no-issue 或无 --issue 静默。
    ISSUE=$(printf '%s' "$COMMAND" \
      | grep -oE -- '--issue[[:space:]]+[A-Za-z0-9_-]+' \
      | head -n1 \
      | sed -E 's/--issue[[:space:]]+//')
    if [ -z "$ISSUE" ]; then
      exit 0
    fi
    cat <<EOF
📋 工单状态提醒：worktree 入口已带 --issue ${ISSUE}。
下一步（规则见 .claude/rules/issue-tracker.md「任务状态与真实交付」）：
1. get_enterprise_issue_detail 查 ${ISSUE} 当前状态。
2. 先核对适用 PRD 的产品评审确认、业务父需求、目标版本、负责人及当前操作授权；业务开发确认子任务已由开发创建并挂业务父需求，缺陷按缺陷关联规则处理；
   满足准入后才按合法路径进入开发中／修复中，不因 worktree 建立就自动改状态。
3. 已有人执行、已在测试或发布阶段、或已终止时，先确认接手／返工范围，不自动抢占或重开。
EOF
    exit 0
    ;;
  mcp__gitee-ent__create_enterprise_repo_pull)
    cat <<'EOF'
📋 工单状态提醒：PR 已创建。若本 PR 关联工单且当前授权包含标签更新，按仓库规则打 ready-for-review 标签
（label id 用 list_enterprise_labels 查；label_ids 是整体语义，先 get 现有标签合并写回）。
EOF
    exit 0
    ;;
  mcp__gitee-ent__merge_enterprise_pull)
    cat <<'EOF'
📋 工单状态提醒：PR 已合并。若本 PR 关联工单，按「任务状态与真实交付」收尾：
- 合并不等于测试、实际部署或共同验收，不自动完成需求／任务／缺陷，也不自动添加旧完成标签。
- 实际部署测试后按授权提测；测试及发布前验收通过后待发布；生产验证及测试、产品共同验收通过才可已上线。
- 纯文档等无需部署的事项按实际交付处理；子任务交付不自动完成父需求。结论由相应负责人确认，Agent 不代签。
EOF
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
