#!/usr/bin/env python3
"""Validate normalized Gitee PR evidence before and after updating a PR."""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
from pathlib import Path

from sync_recovery import RecoveryError, record_verification


MAX_EVIDENCE_AGE_SECONDS = 300


class EvidenceError(RuntimeError):
    pass


def git(root: Path, *args: str) -> str:
    result = subprocess.run(
        ["git", "-C", str(root), *args], text=True, capture_output=True
    )
    if result.returncode != 0:
        raise EvidenceError(result.stderr.strip() or "Git 命令失败。")
    return result.stdout.strip()


def load_snapshot(path: Path) -> dict[str, object]:
    if os.name != "nt":
        try:
            if path.stat().st_mode & 0o077:
                raise EvidenceError("PR 快照权限过宽；临时文件必须 chmod 600。")
        except OSError as exc:
            raise EvidenceError("PR 快照无法检查：{}".format(exc)) from exc
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise EvidenceError("PR 快照无法读取：{}".format(exc)) from exc
    if not isinstance(data, dict):
        raise EvidenceError("PR 快照必须是 JSON object。")
    required = {
        "pull_request_id",
        "state",
        "source_branch",
        "target_branch",
        "head_sha",
        "conflict",
        "changed_files",
        "fetched_at",
    }
    missing = sorted(required - data.keys())
    if missing:
        raise EvidenceError("PR 快照缺少字段：{}".format(", ".join(missing)))
    if not isinstance(data["changed_files"], list) or not all(
        isinstance(item, str) for item in data["changed_files"]
    ):
        raise EvidenceError("PR 快照 changed_files 必须是字符串数组。")
    try:
        age = int(time.time()) - int(data["fetched_at"])
    except (TypeError, ValueError) as exc:
        raise EvidenceError("PR 快照 fetched_at 必须是 Unix 时间戳。") from exc
    if age < -30 or age > MAX_EVIDENCE_AGE_SECONDS:
        raise EvidenceError("PR 快照已过期或时间异常；请通过 Gitee MCP 重新读取。")
    return data


def validate_identity(
    data: dict[str, object], iid: int, branch: str, expected_head: str
) -> None:
    if int(data["pull_request_id"]) != iid:
        raise EvidenceError("PR 快照 IID 与 --update-pr 不匹配。")
    if data["state"] != "opened":
        raise EvidenceError("PR 不是 opened 状态。")
    if data["source_branch"] != branch:
        raise EvidenceError("PR source branch 与当前分支不匹配。")
    if data["target_branch"] != "master":
        raise EvidenceError("PR target branch 不是 master。")
    if data["head_sha"] != expected_head:
        raise EvidenceError("PR head_sha 与预期远端 SHA 不匹配。")


def recovery_file(root: Path) -> Path:
    return Path(git(root, "rev-parse", "--absolute-git-dir")) / "agent-sync-recovery.json"


def changed_files(root: Path) -> list[str]:
    output = git(root, "diff", "--name-only", "origin/master...HEAD")
    return output.splitlines() if output else []


def emit(as_json: bool, status: str, **details: object) -> None:
    payload = {"status": status, **details}
    if as_json:
        print(json.dumps(payload, ensure_ascii=False, sort_keys=True))
    else:
        print("{}: {}".format(status, json.dumps(details, ensure_ascii=False, sort_keys=True)))


def preflight(args: argparse.Namespace, root: Path, data: dict[str, object]) -> int:
    branch = git(root, "symbolic-ref", "--short", "HEAD")
    validate_identity(data, args.iid, branch, args.remote_sha)
    local_files = changed_files(root)
    frozen = set(str(item) for item in data["changed_files"])
    allowed = frozen | set(args.allow_scope_file)
    unexpected = sorted(set(local_files) - allowed)
    if unexpected:
        raise EvidenceError(
            "本地 diff 含冻结范围外文件：{}；仅可用 --allow-scope-file 明确声明经审查修订允许的新文件。".format(
                ", ".join(unexpected)
            )
        )
    emit(
        args.as_json,
        "PR_PREFLIGHT_VERIFIED",
        pull_request_id=args.iid,
        branch=branch,
        remote_sha=args.remote_sha,
        changed_files=local_files,
    )
    return 0


def verify(args: argparse.Namespace, root: Path, data: dict[str, object]) -> int:
    branch = git(root, "symbolic-ref", "--short", "HEAD")
    head = git(root, "rev-parse", "HEAD")
    validate_identity(data, args.iid, branch, head)
    if data["conflict"] is not False:
        raise EvidenceError("PR conflict 必须是 JSON 布尔 false（非字符串 \"false\"）。")
    local_files = changed_files(root)
    if sorted(set(str(item) for item in data["changed_files"])) != sorted(set(local_files)):
        raise EvidenceError("Gitee PR changed_files 与本地最终 diff 不一致。")

    marker = recovery_file(root)
    if marker.exists():
        try:
            record_verification(marker, head, args.iid)
        except RecoveryError as exc:
            raise EvidenceError(str(exc)) from exc

    emit(
        args.as_json,
        "PR_UPDATE_VERIFIED",
        pull_request_id=args.iid,
        branch=branch,
        head=head,
        changed_files=local_files,
    )
    return 0


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("preflight", "verify"))
    parser.add_argument("--update-pr", type=int, required=True, dest="iid")
    parser.add_argument("--pr-snapshot", type=Path, required=True)
    parser.add_argument("--remote-sha", default="")
    parser.add_argument("--allow-scope-file", action="append", default=[])
    parser.add_argument("--json", action="store_true", dest="as_json")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv or sys.argv[1:])
    try:
        root = Path(git(Path.cwd(), "rev-parse", "--show-toplevel")).resolve()
        data = load_snapshot(args.pr_snapshot)
        if args.action == "preflight":
            if not args.remote_sha:
                raise EvidenceError("preflight 缺少 --remote-sha。")
            return preflight(args, root, data)
        return verify(args, root, data)
    except (EvidenceError, TypeError, ValueError) as exc:
        emit(args.as_json, "PR_EVIDENCE_INVALID", detail=str(exc))
        return 8


if __name__ == "__main__":
    raise SystemExit(main())
