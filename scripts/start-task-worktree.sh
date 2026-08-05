#!/usr/bin/env bash
# Compatibility wrapper. All workflow logic lives in start-task-worktree.py.

set -euo pipefail

# pwd -P 取物理路径（getcwd 规范大小写），避免大小写不敏感文件系统上
# 逻辑 PWD 拼写漂移进 ROOT/ENTRY；Python 端另有 samefile 兜底（ADR-0039）。
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
ENTRY="$ROOT/scripts/start-task-worktree.py"

# 复用共享 Python 3 启动器探测：跳过 Microsoft Store 的 app execution alias 桩
# （WindowsApps\python3.exe 会让 command -v 命中，exec 却弹 Store / 报错）。
. "$ROOT/scripts/lib/python3-command.sh"
if select_python3_command; then
  exec "${PYTHON3_COMMAND[@]}" "$ENTRY" "$@"
fi

echo "❌ start-task-worktree: 未找到可用的 Python 3。" >&2
python3_path="$(command -v python3 2>/dev/null || true)"
if [ -n "$python3_path" ]; then
  echo "   检测到的 python3 是 Microsoft Store 桩（${python3_path}），请安装真正的 Python 3 或使用 py -3。" >&2
else
  echo "   macOS/Linux 请使用 python3，Windows 请使用 py -3。" >&2
fi
exit 1
