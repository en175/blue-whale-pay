#!/usr/bin/env bash
# Commit doc-only changes directly on local master (ADR-0025 doc-on-master allowlist).
#
# 场景：AI 在主 checkout master 上直改散文规格文档（CONTEXT.md / docs/**/*.md）后，
#   用本入口落盘 commit。校验改动全在白名单内，避免误把代码/契约/配置一起 commit。
#
# 与 commit-task-for-review.sh 的区别：
#   - 后者在 worktree 工单分支提交任意任务 diff（走 PR→merge）。
#   - 本脚本在本地 master 直提 doc（ADR-0025 例外），不 push、不开 PR——
#     远程同步搭现有发布流程的车（publish-review-package.sh）。
#
# 白名单（与 block-master-edit.sh 保持一致）：根 CONTEXT.md + docs/**/*.md。
# 排除：.claude/、scripts/、代码、docs/specs/*.json schema/契约、fixtures、PDF——
#   改这些仍必须走 task worktree。
#
# 退出码 1 = 校验失败（非 master / 有非白名单改动 / 无改动）。

set -euo pipefail

MESSAGE=""

usage() {
  cat >&2 <<EOF
用法: scripts/commit-spec-on-master.sh -m "<描述>"

在本地 master 直提文档改动（ADR-0025 白名单：CONTEXT.md / docs/**/*.md）。
- 自动加 docs: 前缀（除非 message 已以合法 type: 开头）
- 工作区若混有非白名单改动（代码/契约/配置）→ 拒绝，请先处理
- 不 push、不开 PR
EOF
  exit 2
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    -m|--message) [ "$#" -ge 2 ] || usage; MESSAGE="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "❌ commit-spec-on-master: 不支持的参数：$1" >&2; usage ;;
  esac
done

fail() { echo "❌ commit-spec-on-master: $*" >&2; exit 1; }

[ -n "$MESSAGE" ] || fail "缺少描述。用法: -m \"<描述>\""

ROOT="$(git rev-parse --show-toplevel)"
ROOT="$(cd "$ROOT" && pwd)"

branch="$(git -C "$ROOT" symbolic-ref --short HEAD 2>/dev/null || true)"
[ "$branch" = "master" ] || fail "本脚本仅在本地 master 运行（当前: ${branch:-detached}）。doc 直改走 master；worktree 任务请用 commit-task-for-review.sh。"

# 校验工作区改动全在白名单内（tracked modified/staged 相对 HEAD + untracked）。
# --no-renames：把 rename 拆成 D(旧路径)+A(新路径)分开输出，防止
#   `git mv src/a.py docs/x.md` 只显新路径 docs/x.md 误过白名单（旧路径 src/a.py 必须被捕获）。
# bash 3.2 无 mapfile，用 while read；任何非白名单改动 → fail closed。
non_doc=""
while IFS= read -r f; do
  [ -n "$f" ] || continue
  case "$f" in
    CONTEXT.md|docs/*.md) ;;
    *) non_doc="${non_doc}  ${f}"$'\n' ;;
  esac
done < <(git -C "$ROOT" diff --name-status --no-renames HEAD 2>/dev/null | cut -f2-; git -C "$ROOT" ls-files --others --exclude-standard 2>/dev/null)

if [ -n "$non_doc" ]; then
  printf '❌ 工作区有非白名单改动，本脚本只 commit 文档（ADR-0025: CONTEXT.md / docs/**/*.md）。请先处理：\n%s' "$non_doc" >&2
  exit 1
fi

[ -n "$(git -C "$ROOT" status --porcelain)" ] || fail "没有可提交的文档改动。"

# 默认 docs: 前缀，除非 message 已含合法 conventional type
case "$MESSAGE" in
  feat:*|fix:*|docs:*|style:*|refactor:*|perf:*|test:*|chore:*|build:*|ci:*|revert:*) full="$MESSAGE" ;;
  *) full="docs: $MESSAGE" ;;
esac

git -C "$ROOT" add -A
git -C "$ROOT" commit -m "$full"
echo "✅ 文档已落盘本地 master：$full"
echo "下一步：远程同步走发布流程（publish-review-package.sh）；下个 task worktree 从此 master 切出，自动看到本次文档。"
