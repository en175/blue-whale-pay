#!/usr/bin/env python3
"""Query repository Hook audit records by correlation fields."""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path


NO_MATCH_DIAGNOSTIC = "未进入仓库 Hook 执行链"


class QueryError(RuntimeError):
    pass


def git_common_dir(project_dir: Path) -> Path:
    result = subprocess.run(
        ["git", "-C", str(project_dir), "rev-parse", "--git-common-dir"],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        raise QueryError(result.stderr.strip() or "无法解析 Git common dir")
    common = Path(result.stdout.strip())
    if not common.is_absolute():
        common = project_dir.resolve() / common
    return common.resolve()


def records(audit_dir: Path):
    paths = sorted(audit_dir.glob("*.log.1")) + sorted(audit_dir.glob("*.log"))
    for path in paths:
        try:
            lines = path.read_text(encoding="utf-8").splitlines()
        except OSError as exc:
            raise QueryError(f"无法读取审计日志 {path}: {exc}") from exc
        for line_number, line in enumerate(lines, start=1):
            if not line:
                continue
            try:
                record = json.loads(line)
            except json.JSONDecodeError as exc:
                raise QueryError(
                    f"审计日志不是合法 JSON: {path}:{line_number}: {exc.msg}"
                ) from exc
            if not isinstance(record, dict):
                raise QueryError(f"审计记录不是 JSON object: {path}:{line_number}")
            yield record


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project-dir", type=Path, default=Path.cwd())
    parser.add_argument("--from-utc", default="")
    parser.add_argument("--session-id", default="")
    parser.add_argument("--tool-use-id", default="")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv or sys.argv[1:])
    try:
        audit_dir = git_common_dir(args.project_dir) / "hook-audit"
        matched = 0
        for record in records(audit_dir):
            if args.from_utc and record.get("timestamp", "") < args.from_utc:
                continue
            if args.session_id and record.get("session_id") != args.session_id:
                continue
            if args.tool_use_id and record.get("tool_use_id") != args.tool_use_id:
                continue
            print(json.dumps(record, ensure_ascii=False, separators=(",", ":")))
            matched += 1
        if matched == 0:
            print(NO_MATCH_DIAGNOSTIC)
        return 0
    except QueryError as exc:
        print(f"审计查询失败: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
