#!/usr/bin/env bash
# Blue-Whale — 一键初始化本地开发环境（git hooks + Claude guardrails）
# clone 后跑一次：bash scripts/setup-hooks.sh
# setup 脚本本身仅用 Bash；运行时 pre-push/Work Tree 入口需要 Python 3。
# 支持 macOS/Linux，以及安装 Git for Windows 的 Git Bash。

set -euo pipefail

# 定位仓库根（脚本可能在子目录被调用）
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

echo "=== Blue-Whale 开发环境初始化 ==="
echo ""

# ------------------------------------------------------------
# 1. 配置 git hooks 路径（项目级 core.hooksPath 覆盖全局，指向仓库内 .githooks/）
#    本项仅作用于 Blue-Whale 仓库；其他仓库仍用各自全局/项目配置。
# ------------------------------------------------------------
git config core.hooksPath .githooks
echo "✅ git hooks 已配置：core.hooksPath = .githooks（仅本项目）"
echo "   生效的 hook："
echo "   - pre-commit：禁提交生成物 + 前端 lint 软提醒 + 后端 py_compile 软提醒 + 工单分支落后软提醒（允许用户本地 master commit）"
echo "   - commit-msg：Conventional Commits 规范校验"
echo "   - pre-push：禁直推 master/main + 非结构化中文分支名拦截 + 工单分支落后 origin/master 硬拦"
echo "     运行依赖：Python 3（macOS/Linux 使用 python3；Windows Git Bash 使用 py -3）"
echo "   - post-commit/post-checkout：graphify 知识图谱自动重建"
echo ""

# ------------------------------------------------------------
# 2. 确保 hook 脚本可执行（clone 后权限偶发丢失）
# ------------------------------------------------------------
chmod +x .githooks/* .claude/hooks/*.sh scripts/*.sh 2>/dev/null || true
echo "✅ hook / workflow 脚本权限已就绪"
mode_changes="$(git diff --summary -- .githooks .claude/hooks scripts | sed -n '/mode change/p' || true)"
if [ -n "$mode_changes" ]; then
  echo "⚠️  初始化后发现可执行权限未提交到仓库，当前工作区会显示 mode change："
  printf '%s\n' "$mode_changes" | sed 's/^/   /'
  echo "   请在 chore 分支提交这些权限位，避免后续初始化反复产生 dirty 状态。"
fi
echo ""

# ------------------------------------------------------------
# 3. Claude Code guardrails 说明
#    .claude/hooks/block-*.sh + .claude/settings.json 已随仓库提供（进版本控制），
#    Claude Code 自动加载，无需本脚本生成。个人本机配置请放 .claude/settings.local.json。
# ------------------------------------------------------------
echo "✅ Claude guardrails 已随仓库就绪（.claude/settings.json + .claude/hooks/）"
echo "   - block-dangerous-git.sh：拦 AI 破坏性 git（裸 --force / reset --hard / branch -D / checkout . 等）"
echo "   - block-push-to-master.sh：拦 AI 直推 master/main（与 .githooks/pre-push 形成双层防护，AI 走 MCP 合并 / 本地 git push 都挡）"
echo "   - confirm-release-action.sh：拦 AI 用 squash/rebase 合并 PR（强制 merge）；拦发布动作缺授权/缺标准入口"
echo "   - block-issue-without-repo.sh：拦 AI 创建仓库不可见 issue / 子 issue 未继承父项归属"
echo "   个人配置请放 .claude/settings.local.json"
echo ""

# ------------------------------------------------------------
# 4. Gitee 凭证提示（.mcp.json 引用环境变量，需本机配置一次）
# ------------------------------------------------------------
echo "=== 后续步骤（按需执行）==="
echo "  export GITEE_ACCESS_TOKEN=<你的 Gitee 私人令牌>   # 写进 ~/.zshrc 持久化"
echo "  cd blue_whale_web && npm install                  # 前端依赖（首次必装）"
echo ""
echo "=== 完成。提交/推送时 hook 自动生效 ==="
