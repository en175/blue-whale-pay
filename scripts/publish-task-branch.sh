#!/usr/bin/env bash
# Deprecated: use an explicit publish-review-package create/update mode.

set -euo pipefail

cat >&2 <<EOF
❌ publish-task-branch 已废弃。

发布必须显式选择入口模式：
  首次创建：scripts/publish-review-package.sh --user-authorized --create-pr
  更新已有：scripts/publish-review-package.sh --user-authorized --update-pr <PR编号> --pr-snapshot <临时JSON>

Agent 依据 CLAUDE.md 主动选择；Hook 只在缺授权、缺模式或绕过入口时阻断。
EOF
exit 2
