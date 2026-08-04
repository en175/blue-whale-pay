#!/usr/bin/env bash
# Claude Code PreToolUse hook — 拦截 AI 的破坏性 git 操作（仅本项目）
# JSON 与 shell 命令解析委托给 lib/pretool.py，避免转义引号和 git 全局选项绕过。
#
# 拦截清单：
#   - 裸 --force / -f 的 git push（任何分支，无差别拦）
#   - 对保护分支（master/main）的 force-with-lease 强推
#   - git reset --hard
#   - git clean -f / -fd
#   - git branch -D（强删分支）
#   - git checkout . / git restore .（丢弃工作区改动）
#
# 放行清单（rebase 工作流必需）：
#   - 对 feature/* fix/* hotfix/* docs/* chore/* 等工单分支的 git push --force-with-lease
#     （feature 分支是 AI 的私有作业区，rebase 后需强推；--force-with-lease
#      本身有安全网：远程被别人动过会自动拒绝。）
#
# 设计原则：master 受保护、合并走 PR；工单分支私有，rebase 后允许 --force-with-lease。
# 退出码 2 = 阻断 Claude 执行该命令。

INPUT=$(cat)
HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
PRETOOL="$HOOK_DIR/lib/pretool.py"
AUDIT="$HOOK_DIR/lib/hook_audit.py"
HOOK_NAME="$(basename "$0")"
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
COMMAND=$(printf '%s' "$INPUT" | python3 "$PRETOOL" value command 2>/dev/null || true)

audit() {
  printf '%s' "$INPUT" | python3 "$AUDIT" \
    --project-dir "$PROJECT_DIR" \
    --hook "$HOOK_NAME" \
    --operation "$1" \
    --exit-code "$2" \
    --reason "$3" >/dev/null || true
}

if [ -z "$COMMAND" ]; then
  audit "bash-other" 0 "allowed-policy"
  exit 0
fi

# ============================================================
# push 的精细化处理：区分 force-with-lease（feature 分支放行）与裸 --force（全拦）
# ============================================================
if printf '%s' "$COMMAND" | python3 "$PRETOOL" has-git-push; then
  # 规则 1：裸 --force（无 -with-lease）→ 无条件拦
  if printf '%s' "$COMMAND" | python3 "$PRETOOL" push-has-bare-force; then
    audit "git-push-bare-force" 2 "blocked-policy"
    cat >&2 <<EOF
BLOCKED: 裸 --force 被拦截。
  命令: $COMMAND

本项目禁止 AI 使用裸 --force / -f（会无脑覆盖远程历史，无视他人改动）。
- rebase 后强推 feature 分支：改用 git push --force-with-lease
- master 受保护，合并走 PR，任何强推都被拦
- 详见 CLAUDE.md「提交与审查」
EOF
    exit 2
  fi

  # 规则 2：force-with-lease 但目标非工单分支（含 master/main/当前在 master）→ 拦
  target_ref=$(printf '%s' "$COMMAND" | python3 "$PRETOOL" force-lease-non-work 2>/dev/null || true)
  if [ -n "$target_ref" ]; then
    audit "git-push-force-with-lease" 2 "blocked-policy"
    cat >&2 <<EOF
BLOCKED: 对非工单分支的 force-with-lease 被拦截。
  命令: $COMMAND
  推断目标: ${target_ref:-（当前分支，疑似保护分支）}

--force-with-lease 仅允许用于 feature/* fix/* hotfix/* docs/* chore/* 工单分支（rebase 后强推）。
- master/main 等保护分支禁止强推，合并走 PR
- 若你在工单分支但被误判，确认分支名以 feature//fix//hotfix//docs//chore/ 开头
- 详见 CLAUDE.md「提交与审查」
EOF
    exit 2
  fi

  # 规则 3：force-with-lease + 工单分支 → 放行
  # （落入下方通用危险模式检查，不再被 force 规则拦）
fi

# ============================================================
# 其余破坏性操作（非 push 类）
# ============================================================
pattern=$(printf '%s' "$COMMAND" | python3 "$PRETOOL" dangerous-pattern 2>/dev/null || true)
if [ -n "$pattern" ]; then
  case "$pattern" in
    "git reset --hard") operation="git-reset-hard" ;;
    "git clean -f") operation="git-clean-force" ;;
    "git branch -D") operation="git-branch-force-delete" ;;
    "git checkout .") operation="git-checkout-all" ;;
    "git restore .") operation="git-restore-all" ;;
    *) operation="git-dangerous-other" ;;
  esac
  audit "$operation" 2 "blocked-policy"
  cat >&2 <<EOF
BLOCKED: 危险 git 操作被拦截。
  命令: $COMMAND
  匹配: $pattern

本项目禁止 AI 执行破坏性 git 操作（硬重置/清空/强删分支/丢弃改动）。
- 推代码: 用普通 git push（推到 feature 分支走 PR）
- master 受保护，合并走 PR
- 详见 CLAUDE.md「提交与审查」
EOF
  exit 2
fi

if printf '%s' "$COMMAND" | python3 "$PRETOOL" has-git-push; then
  audit "git-push-non-dangerous" 0 "allowed-policy"
else
  audit "bash-other" 0 "allowed-policy"
fi
exit 0
