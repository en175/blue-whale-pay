#!/usr/bin/env bash
# Probe the real Codex apply_patch hook path without applying any patch.

set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CODEX_HOOKS_JSON="$REPO_ROOT/.codex/hooks.json"
TMP_ROOT=""

cleanup() {
  if [ -n "$TMP_ROOT" ] && [ -d "$TMP_ROOT" ]; then
    rm -rf "$TMP_ROOT"
  fi
}
trap cleanup EXIT

fail() {
  echo "probe failed: $*" >&2
  exit 1
}

if ! CODEX_COMMAND="$(python3 - "$CODEX_HOOKS_JSON" <<'PY'
import json
import shlex
import sys
from pathlib import Path

path = Path(sys.argv[1])
try:
    config = json.loads(path.read_text())
    pre_hooks = config["hooks"]["PreToolUse"]
except (OSError, json.JSONDecodeError, KeyError, TypeError) as error:
    raise SystemExit(f"unable to parse real Codex hook config {path}: {error}")

matches = [item for item in pre_hooks if item.get("matcher") == "Edit|Write"]
if len(matches) != 1:
    raise SystemExit(
        "expected exactly one Codex PreToolUse matcher=Edit|Write, "
        f"found {len(matches)}"
    )

commands = [
    hook.get("command", "")
    for hook in matches[0].get("hooks", [])
    if hook.get("type") == "command"
]
if len(commands) != 1:
    raise SystemExit(
        "expected matcher=Edit|Write to contain exactly one command hook, "
        f"found {len(commands)}"
    )

command = commands[0]
try:
    parts = shlex.split(command)
except ValueError as error:
    raise SystemExit(f"invalid Codex Edit|Write command: {error}")

expected_wrapper = "$(git rev-parse --show-toplevel)/.codex/hooks/run-claude-pretool.sh"
if (
    len(parts) != 3
    or Path(parts[0]).name not in {"bash", "sh"}
    or parts[1] != expected_wrapper
    or parts[2] != "block-master-edit.sh"
):
    raise SystemExit(
        "matcher=Edit|Write must execute the real Codex wrapper "
        "run-claude-pretool.sh with shared gate block-master-edit.sh; "
        f"actual command={command!r}"
    )

print(command)
PY
)"; then
  exit 1
fi

make_input() {
  local cwd="$1"
  local operation="$2"
  python3 - "$cwd" "$operation" <<'PY'
import json
import sys

cwd, operation = sys.argv[1:]
patches = {
    "create": "*** Begin Patch\n*** Add File: created.txt\n+created\n*** End Patch",
    "update": "*** Begin Patch\n*** Update File: existing.txt\n@@\n-before\n+after\n*** End Patch",
}
print(
    json.dumps(
        {
            "tool_name": "apply_patch",
            "cwd": cwd,
            "tool_input": {"command": patches[operation]},
        }
    )
)
PY
}

run_case() {
  local area="$1"
  local operation="$2"
  local expected_exit="$3"
  local cwd="$4"
  local input tmp_out tmp_err actual_exit actual_stdout actual_stderr

  input="$(make_input "$cwd" "$operation")" || fail "$area $operation: unable to build official apply_patch input"
  tmp_out="$(mktemp "${TMPDIR:-/tmp}/codex-write-probe-out.XXXXXX")" || fail "$area $operation: unable to create stdout capture"
  tmp_err="$(mktemp "${TMPDIR:-/tmp}/codex-write-probe-err.XXXXXX")" || {
    rm -f "$tmp_out"
    fail "$area $operation: unable to create stderr capture"
  }

  (
    cd "$REPO_ROOT" || exit 1
    printf '%s' "$input" | bash -c "$CODEX_COMMAND"
  ) >"$tmp_out" 2>"$tmp_err"
  actual_exit=$?
  actual_stdout="$(cat "$tmp_out")"
  actual_stderr="$(cat "$tmp_err")"
  rm -f "$tmp_out" "$tmp_err"

  if [ "$actual_exit" -ne "$expected_exit" ]; then
    fail "$area $operation: expected exit=$expected_exit, actual exit=$actual_exit; stdout=${actual_stdout:-<empty>}; stderr=${actual_stderr:-<empty>}"
  fi
  if [ -n "$actual_stdout" ]; then
    fail "$area $operation: expected empty stdout, actual=${actual_stdout}"
  fi
  if [ "$expected_exit" -eq 2 ]; then
    case "$actual_stderr" in
      *"BLOCKED:"*) ;;
      *) fail "$area $operation: expected blocking reason on stderr, actual=${actual_stderr:-<empty>}" ;;
    esac
  elif [ -n "$actual_stderr" ]; then
    fail "$area $operation: expected empty stderr, actual=${actual_stderr}"
  fi
}

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/codex-write-hook-probe.XXXXXX")" || fail "unable to create temporary probe root"
MASTER_REPO="$TMP_ROOT/master"
TASK_REPO="$TMP_ROOT/task"
mkdir -p "$MASTER_REPO" "$TASK_REPO" || fail "unable to create temporary Git repositories"

git -C "$MASTER_REPO" init -q || fail "unable to initialize temporary master repository"
git -C "$MASTER_REPO" symbolic-ref HEAD refs/heads/master || fail "unable to set temporary master branch"
git -C "$TASK_REPO" init -q || fail "unable to initialize temporary task repository"
git -C "$TASK_REPO" symbolic-ref HEAD refs/heads/feature/probe || fail "unable to set temporary task branch"
printf 'before\n' >"$MASTER_REPO/existing.txt"
printf 'before\n' >"$TASK_REPO/existing.txt"

run_case master create 2 "$MASTER_REPO"
run_case master update 2 "$MASTER_REPO"
run_case task create 0 "$TASK_REPO"
run_case task update 0 "$TASK_REPO"

[ ! -e "$MASTER_REPO/created.txt" ] || fail "master create: probe unexpectedly applied the patch"
[ ! -e "$TASK_REPO/created.txt" ] || fail "task create: probe unexpectedly applied the patch"
[ "$(cat "$MASTER_REPO/existing.txt")" = "before" ] || fail "master update: probe unexpectedly modified the file"
[ "$(cat "$TASK_REPO/existing.txt")" = "before" ] || fail "task update: probe unexpectedly modified the file"

echo "matcher=Edit|Write"
echo "tool_name=apply_patch"
echo "tool_input=command"
echo "master create=blocked"
echo "master update=blocked"
echo "task create=allowed"
echo "task update=allowed"
