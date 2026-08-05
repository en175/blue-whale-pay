#!/usr/bin/env bash
# Compatibility wrapper. All synchronization logic lives in sync-task-from-origin.py.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENTRY="$ROOT/scripts/sync-task-from-origin.py"
. "$ROOT/scripts/lib/python3-command.sh"

if select_python3_command; then
  exec "${PYTHON3_COMMAND[@]}" "$ENTRY" "$@"
fi

echo "❌ sync-task-from-origin: 未找到可用的 Python 3。" >&2
exit 1
