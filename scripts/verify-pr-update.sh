#!/usr/bin/env bash
# Verify a post-push Gitee PR snapshot before finalizing a sync transaction.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/lib/python3-command.sh"

if select_python3_command; then
  exec "${PYTHON3_COMMAND[@]}" "$ROOT/scripts/pr-update-evidence.py" verify "$@"
fi

echo "❌ verify-pr-update: 未找到可用的 Python 3。" >&2
exit 1
