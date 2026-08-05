#!/usr/bin/env bash
# Claude Code PreToolUse hook — 拦截 AI 在 master 分支直接 Edit/Write 文件
#
# 拦截对象：
#   - Edit 工具（agent 编辑文件时触发）
#   - Write 工具（agent 创建文件时触发）
#   当 Edit/Write 目标文件所属工作树的 git 分支为 master 时拦截。
#
# 放行：
#   - 目标文件在非 master 分支的工作树（工单分支 worktree / detached HEAD）
#   - 目标文件不在任何 git 工作树内（仓库外 dotfile，如 ~/.codex/config.toml）
#   - master 分支但目标是已被 Git 忽略的根 CLAUDE.local.md 或 .codex/config.toml
#   - master 分支但目标在文档白名单（根 CONTEXT.md + docs/**/*.md；ADR-0025）
#   - 非 Edit/Write 工具
#
# 为什么拦：Agent 不得在本地 master 直接修改文件。
#   所有改动必须在工单分支 worktree 中完成，走分支→PR→合并流程。
#   决策见 docs/adr/0010-local-master-is-user-integration-zone.md
#
# 分支判定按 file_path 所属工作树（git -C），不看 cwd：
#   主 checkout session（cwd=master）编辑 worktree 工单分支文件时，
#   按 file_path 解析得到工单分支 → 放行，不依赖「worktree 必在主 toplevel 外」的布局假设。
#
# 审计闭环（IK10CW）：对仓库内 Edit/Write 的判定（阻断或放行）追加一条单行
#   结构化审计记录（时间/hook/工具/file_path/分支/session_id/tool_use_id/exit_code/reason）。
#   审计只记判定元数据，不记文件内容/命令/凭证；成功或失败均不改变原 exit code、
#   stdout 契约或既有阻断信息（降级时仅在 stderr 留简短提示）。
#   非 Edit/Write 工具与仓库外文件操作不审计（IK10CW out of scope）。
#
# 退出码 2 = 阻断 Claude 执行该工具调用。

INPUT=$(cat)
HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
PRETOOL="$HOOK_DIR/lib/pretool.py"
AUDIT="$HOOK_DIR/lib/hook_audit.py"
HOOK_NAME="$(basename "$0")"
TOOL_NAME=$(printf '%s' "$INPUT" | python3 "$PRETOOL" value tool_name 2>/dev/null || true)

# audit <exit_code> <reason>：判定完成后、返回前调用；失败不改变 exit code。
# stdin 复用原 INPUT，让 helper 读 tool_name/tool_use_id/session_id/file_path。
# project-dir 用 file_path 所属工作树的 TOPLEVEL（已解析），不用会话级
# CLAUDE_PROJECT_DIR——否则主 checkout 会话编辑 worktree 临时仓库文件时，
# 审计事件会错误落到真实仓库的 common dir，污染真实审计流。
# stdout 重定向到 /dev/null（守护 stdout 空契约）；stderr 透传——降级时 helper
# 在 stderr 留「hook-audit: degraded (...)」简短提示，符合 IK10CW 降级语义。
audit() {
  printf '%s' "$INPUT" | python3 "$AUDIT" \
    --project-dir "$TOPLEVEL" \
    --hook "$HOOK_NAME" \
    --branch "$BRANCH" \
    --include-file-context \
    --operation "file-write" \
    --exit-code "$1" \
    --reason "$2" >/dev/null || true
}

# 只处理 Edit / Write 工具
case "$TOOL_NAME" in
  Edit|Write) ;;
  *) exit 0 ;;
esac

# 取 Edit/Write 目标文件路径
FILE_PATH=$(printf '%s' "$INPUT" | python3 "$PRETOOL" value file_path 2>/dev/null || true)

# 按目标文件所属工作树解析分支与 toplevel（不看 cwd，去 worktree 路径布局假设）
#   dirname("")="."：file_path 缺失时退化为 cwd 分支判定（保留旧行为）
FILE_DIR="$(dirname "$FILE_PATH")"
BRANCH=$(git -C "$FILE_DIR" symbolic-ref --short HEAD 2>/dev/null || echo "")
TOPLEVEL=$(git -C "$FILE_DIR" rev-parse --show-toplevel 2>/dev/null || echo "")

# file_path 父目录尚不存在（如 Write 全新子目录文件）→ git -C 失败、BRANCH/TOPLEVEL 空。
# 向上遍历到最近存在的祖先目录重试，否则误判「仓库外」放行，master 内新文件漏拦。
if [ -z "$BRANCH" ] && [ -z "$TOPLEVEL" ] && [ -n "$FILE_DIR" ] && [ "$FILE_DIR" != "/" ]; then
  ancestor="$FILE_DIR"
  while [ "$ancestor" != "/" ] && [ ! -d "$ancestor" ]; do
    ancestor="$(dirname "$ancestor")"
  done
  if [ "$ancestor" != "/" ] && [ -d "$ancestor" ] && [ "$ancestor" != "$FILE_DIR" ]; then
    BRANCH=$(git -C "$ancestor" symbolic-ref --short HEAD 2>/dev/null || echo "")
    TOPLEVEL=$(git -C "$ancestor" rev-parse --show-toplevel 2>/dev/null || echo "")
  fi
fi

# 目标文件不在任何 git 工作树内（仓库外）→ 放行
if [ -z "$TOPLEVEL" ]; then
  exit 0
fi

# 非 master 分支（工单分支 worktree / detached HEAD）→ 放行并审计
if [ "$BRANCH" != "master" ]; then
  audit 0 "allowed-non-master"
  exit 0
fi

# master 分支但目标在文档白名单 → 放行（AI 可直改散文规格文档；ADR-0025）
#   白名单：根 CONTEXT.md（领域语言权威源）+ docs/**/*.md（纯记录散文）。
#   仍拦：.claude/（hooks/settings/rules/CLAUDE.md 规则源）、scripts/、代码、
#         docs/specs/*.json schema/契约、fixtures、PDF——改这些=改行为，走 worktree。
#   实化 FILE_PATH 目录（解 macOS /var→/private/var 等 symlink）再剥离 TOPLEVEL 前缀；
#   剥离失败（文件不在本工作树根下）→ 不命中，落入下方硬拦（fail closed）。
if REAL_DIR="$(cd "$FILE_DIR" 2>/dev/null && pwd -P)" && [ -n "$REAL_DIR" ]; then
  REL_PATH="${REAL_DIR%/}/$(basename "$FILE_PATH")"
  REL_PATH="${REL_PATH#$TOPLEVEL/}"

  # 本地个人配置只有同时满足「精确路径 + Git 已忽略」才放行。
  # 路径白名单防止扩大 master 写面；check-ignore 防止配置意外进入团队仓库。
  case "$REL_PATH" in
    CLAUDE.local.md|.codex/config.toml)
      if git -C "$TOPLEVEL" check-ignore -q -- "$REL_PATH" 2>/dev/null; then
        audit 0 "allowed-local-personal-config"
        exit 0
      fi
      ;;
  esac

  case "$REL_PATH" in
    CONTEXT.md|docs/*.md)
      audit 0 "allowed-doc-allowlist"
      exit 0
      ;;
  esac
fi

# master 分支 + 仓库内 Edit/Write → 硬拦并审计
audit 2 "blocked-master"
cat >&2 <<EOF
BLOCKED: 禁止在 master 分支直接 Edit/Write 文件。
  工具: $TOOL_NAME

Agent 不得在本地 master 直接修改文件（最高红线）。
- 请使用唯一入口创建 task worktree：scripts/start-task-worktree.sh --type fix --issue IK094T --summary 修复工作树写入护栏
- 在 worktree 的工单分支上完成开发后，走 PR 流程合并
- 详见 CLAUDE.md「Task Worktree」与 docs/agents/worktree-workflow.md
EOF
exit 2
