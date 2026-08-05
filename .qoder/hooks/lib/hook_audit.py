#!/usr/bin/env python3
"""Append-only audit log for blocking PreToolUse hooks.

Records one structured JSON line per hook invocation, capturing only the
metadata needed to answer "was this hook actually called?" plus a bounded
stable operation category chosen by the gate — never file contents, commands,
tool parameter values, tokens, or credentials.

Design contract (IK10CW):
  - Audit success or failure MUST NOT change the hook's exit code, stdout,
    or existing stderr block message.
  - On audit failure, a short degradation notice is written to stderr only.
  - Active log rotates at 10 MiB, keeping at most one archive.
  - Concurrent appends are serialized via fcntl.flock; each record stays a
    complete single line.

The log lives under the shared git common dir (``.git/hook-audit/``), so
the main checkout and all task worktrees write to the same physical file.
Git never tracks anything under ``.git/``, satisfying the "not in version
control" requirement without an extra .gitignore entry.
"""

from __future__ import annotations

import argparse
import fcntl
import json
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

MAX_BYTES = 10 * 1024 * 1024  # 10 MiB
LOG_DIR_NAME = "hook-audit"


def git_common_dir(project_dir: str) -> Path:
    """Resolve the shared git common dir for project_dir.

    Worktrees share one common dir, so the main checkout and all task
    worktrees write to the same physical audit log.
    """
    root = Path(project_dir).resolve()
    result = subprocess.run(
        ["git", "-C", str(root), "rev-parse", "--git-common-dir"],
        capture_output=True,
        text=True,
        check=False,
    )
    common = result.stdout.strip()
    if not common:
        common = str(root / ".git")
    common_path = Path(common)
    if not common_path.is_absolute():
        common_path = root / common_path
    return common_path


def log_paths(project_dir: str, hook_name: str) -> tuple[Path, Path, Path]:
    """Return (active_log, archive, lock_file) under the shared git common dir."""
    base = git_common_dir(project_dir) / LOG_DIR_NAME
    safe_name = hook_name.replace("/", "_")
    active = base / f"{safe_name}.log"
    archive = base / f"{safe_name}.log.1"
    lock = base / f"{safe_name}.log.lock"
    return active, archive, lock


def _scalar_str(value: object) -> str:
    """Coerce a value to a bounded audit field, dropping non-strings.

    Only plain strings are recorded verbatim; booleans/numbers become their
    text form. Objects, arrays, and anything that could embed file contents,
    commands, or credentials are reduced to an empty string — never ``str()``,
    which would serialize nested structures and leak their payloads.
    """
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, (int, float)):
        return str(value)
    if isinstance(value, str):
        return value
    return ""


def read_upstream_fields(include_file_context: bool) -> dict[str, str]:
    """Parse safe top-level correlation fields from stdin JSON.

    ``file_path`` is read only for the master Edit/Write gate, which opts in
    explicitly. Other Bash/MCP gates never copy any ``tool_input`` value into
    the audit record. Missing identifiers are kept as empty strings and
    non-string values are coerced to empty strings.
    """
    try:
        data = json.load(sys.stdin)
    except Exception:
        return {}
    if not isinstance(data, dict):
        return {}
    tool_input = data.get("tool_input")
    if not isinstance(tool_input, dict):
        tool_input = {}
    return {
        "tool": _scalar_str(data.get("tool_name")),
        # Kimi CLI 的关联 id 字段是 tool_call_id；Claude 系平台是 tool_use_id。
        "tool_use_id": _scalar_str(data.get("tool_use_id") or data.get("tool_call_id")),
        "session_id": _scalar_str(data.get("session_id")),
        # Kimi CLI 的 Write/Edit 参数名是 path；Claude 系平台是 file_path。
        "file_path": _scalar_str(
            tool_input.get("file_path") or tool_input.get("path") or data.get("file_path")
        )
        if include_file_context
        else "",
    }


def maybe_rotate(active: Path, archive: Path) -> None:
    """Rename active -> archive if active exceeds MAX_BYTES; drop old archive."""
    try:
        size = active.stat().st_size
    except FileNotFoundError:
        return
    if size < MAX_BYTES:
        return
    if archive.exists():
        archive.unlink()
    active.rename(archive)


def append_record(
    active: Path,
    archive: Path,
    lock: Path,
    record: dict,
) -> None:
    """Append one JSON line under an exclusive flock, rotating when needed.

    Rotation runs both before (handles a log already at/over threshold from a
    prior append) and after (handles this append crossing the threshold) the
    write, so the active log never settles at or above MAX_BYTES.
    """
    active.parent.mkdir(parents=True, exist_ok=True)
    line = json.dumps(record, ensure_ascii=False, separators=(",", ":")) + "\n"
    with open(lock, "a") as lock_fd:
        fcntl.flock(lock_fd.fileno(), fcntl.LOCK_EX)
        try:
            maybe_rotate(active, archive)
            with open(active, "a") as log_fd:
                log_fd.write(line)
            # Post-append rotation: if this write crossed the threshold, rotate
            # now so the active log never rests at >= MAX_BYTES.
            maybe_rotate(active, archive)
        finally:
            fcntl.flock(lock_fd.fileno(), fcntl.LOCK_UN)


def run() -> int:
    parser = argparse.ArgumentParser(description="Append a hook audit record.")
    parser.add_argument("--project-dir", required=True,
                        help="git work tree toplevel (for resolving git-common-dir)")
    parser.add_argument("--hook", required=True,
                        help="hook script name, e.g. block-master-edit.sh")
    parser.add_argument("--branch", default="",
                        help="resolved branch of the target file_path (empty if detached)")
    parser.add_argument("--include-file-context", action="store_true",
                        help="record file_path/branch for the master Edit/Write gate")
    parser.add_argument("--operation", required=True,
                        help="bounded stable operation category chosen by the gate")
    parser.add_argument("--exit-code", required=True,
                        help="exit code the hook will return (0 or 2)")
    parser.add_argument("--reason", required=True,
                        help="short stable reason tag, e.g. blocked-master")
    args = parser.parse_args()

    upstream = read_upstream_fields(args.include_file_context)
    record = {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "hook": args.hook,
        "tool": upstream["tool"],
        "file_path": upstream["file_path"],
        "branch": args.branch if args.include_file_context else "",
        "operation": args.operation[:64],
        "session_id": upstream["session_id"],
        "tool_use_id": upstream["tool_use_id"],
        "exit_code": int(args.exit_code),
        "reason": args.reason,
    }

    active, archive, lock = log_paths(args.project_dir, args.hook)
    append_record(active, archive, lock, record)
    return 0


def main() -> int:
    try:
        return run()
    except SystemExit:
        # argparse raises SystemExit on bad args; let it propagate so the
        # developer sees the usage error during testing. The calling hook
        # guards with ``|| true``.
        raise
    except Exception as exc:
        # Degraded: audit must not change the hook's exit code or stdout.
        # Only a short notice is left on stderr.
        print(f"hook-audit: degraded ({type(exc).__name__})", file=sys.stderr)
        return 0


if __name__ == "__main__":
    raise SystemExit(main())
