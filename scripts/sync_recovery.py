#!/usr/bin/env python3
"""Single atomic persistence boundary for task-sync recovery records."""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path


class RecoveryError(RuntimeError):
    pass


def load_recovery(path: Path) -> dict[str, object]:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise RecoveryError("同步恢复点无法读取：{}".format(exc)) from exc
    if not isinstance(data, dict):
        raise RecoveryError("同步恢复点必须是 JSON object。")
    return data


def write_recovery(path: Path, data: dict[str, object]) -> None:
    temporary = Path(str(path) + ".tmp")
    try:
        temporary.write_text(
            json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
        )
        os.chmod(temporary, 0o600)
        temporary.replace(path)
    except OSError as exc:
        raise RecoveryError("同步恢复点无法原子写入：{}".format(exc)) from exc


def set_push_state(path: Path, head: str, state: str) -> None:
    data = load_recovery(path)
    if state == "clear":
        data.pop("pushed_head", None)
        data.pop("push_state", None)
    else:
        # pushed_head 在 in_flight 与 pushed 两阶段均写入，仅靠 push_state 区分阶段：
        # in_flight 表示推送结果未确认，pushed 表示已确认推送成功。
        # 单看 pushed_head 不能判定是否真已推送，须配合 push_state。
        data["pushed_head"] = head
        data["push_state"] = state
    write_recovery(path, data)


def record_verification(path: Path, head: str, iid: int) -> None:
    data = load_recovery(path)
    if data.get("pushed_head") != head or data.get("push_state") != "pushed":
        raise RecoveryError("同步恢复点未记录当前 HEAD 的成功推送。")
    data["verified_head"] = head
    data["verified_pr_iid"] = iid
    write_recovery(path, data)


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="action", required=True)
    state = subparsers.add_parser("set-push-state")
    state.add_argument("path", type=Path)
    state.add_argument("head")
    state.add_argument("state", choices=("in_flight", "pushed", "clear"))
    verify = subparsers.add_parser("record-verification")
    verify.add_argument("path", type=Path)
    verify.add_argument("head")
    verify.add_argument("iid", type=int)
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv or sys.argv[1:])
    try:
        if args.action == "set-push-state":
            set_push_state(args.path, args.head, args.state)
        else:
            record_verification(args.path, args.head, args.iid)
        return 0
    except RecoveryError as exc:
        print(str(exc), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
