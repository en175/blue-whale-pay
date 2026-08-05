#!/usr/bin/env python3
"""Validate the blocking hook contract shared by supported agent platforms."""

from __future__ import annotations

import argparse
import json
import re
import shlex
import sys
from collections import Counter
from pathlib import Path
from typing import Callable, Optional


Contract = tuple[str, str, str]
CommandParser = Callable[[str], Optional[str]]

EXPECTED_CONTRACTS: tuple[Contract, ...] = (
    ("PreToolUse", "Edit|Write", "block-master-edit.sh"),
    ("PreToolUse", "Bash", "block-dangerous-git.sh"),
    ("PreToolUse", "Bash", "block-push-to-master.sh"),
    ("PreToolUse", "Bash", "confirm-release-action.sh"),
    (
        "PreToolUse",
        "mcp__gitee-ent__create_enterprise_repo_pull",
        "confirm-release-action.sh",
    ),
    (
        "PreToolUse",
        "mcp__gitee-ent__merge_enterprise_pull",
        "confirm-release-action.sh",
    ),
    (
        "PreToolUse",
        "mcp__gitee-ent__create_enterprise_repo_release",
        "confirm-release-action.sh",
    ),
    (
        "PreToolUse",
        "mcp__gitee-ent__create_enterprise_issue",
        "block-issue-without-repo.sh",
    ),
    (
        "PreToolUse",
        "mcp__gitee-ent__update_enterprise_issue",
        "block-issue-without-repo.sh",
    ),
    (
        "PostToolUse",
        "mcp__gitee-ent__create_enterprise_repo_pull",
        "confirm-release-action.sh",
    ),
    (
        "PostToolUse",
        "mcp__gitee-ent__merge_enterprise_pull",
        "confirm-release-action.sh",
    ),
    (
        "PostToolUse",
        "mcp__gitee-ent__create_enterprise_repo_release",
        "confirm-release-action.sh",
    ),
    # 纯提醒型（恒 exit 0，不阻断）：工单状态机流转提醒，
    # 规则见 .claude/rules/issue-tracker.md「任务状态机」。
    ("PostToolUse", "Bash", "remind-issue-state.sh"),
    (
        "PostToolUse",
        "mcp__gitee-ent__create_enterprise_repo_pull",
        "remind-issue-state.sh",
    ),
    (
        "PostToolUse",
        "mcp__gitee-ent__merge_enterprise_pull",
        "remind-issue-state.sh",
    ),
)

GATE_NAME = re.compile(r"[A-Za-z0-9._-]+\.sh")
CLAUDE_HOOK_PATH = re.compile(r".*/\.claude/hooks/([A-Za-z0-9._-]+\.sh)")
CODEX_WRAPPER = "$(git rev-parse --show-toplevel)/.codex/hooks/run-claude-pretool.sh"
KIMI_SHIM = "$HOME/.kimi-code/hooks/blue-whale-hook.sh"


def claude_gate(command: str) -> str | None:
    try:
        parts = shlex.split(command)
    except ValueError:
        return None
    if len(parts) != 1:
        return None
    match = CLAUDE_HOOK_PATH.fullmatch(parts[0])
    return match.group(1) if match else None


def codex_gate(command: str) -> str | None:
    try:
        parts = shlex.split(command)
    except ValueError:
        return None

    if len(parts) == 2:
        wrapper, gate = parts
    elif len(parts) == 3 and Path(parts[0]).name in {"bash", "sh"}:
        _, wrapper, gate = parts
    else:
        return None
    if wrapper != CODEX_WRAPPER:
        return None
    return gate if GATE_NAME.fullmatch(gate) else None


def kimi_gate(command: str) -> str | None:
    try:
        parts = shlex.split(command)
    except ValueError:
        return None

    if len(parts) == 3 and Path(parts[0]).name in {"bash", "sh"}:
        _, shim, gate = parts
    elif len(parts) == 2:
        shim, gate = parts
    else:
        return None
    if shim != KIMI_SHIM:
        return None
    return gate if GATE_NAME.fullmatch(gate) else None


def kimi_normalized_contracts(config: dict[str, object]) -> Counter[Contract]:
    """Normalize Kimi CLI TOML hooks (a flat [[hooks]] list) into contracts."""
    contracts: Counter[Contract] = Counter()
    items = config.get("hooks", [])
    if not isinstance(items, list):
        raise ValueError("Kimi hooks 配置缺少 [[hooks]] 数组")
    for item in items:
        if not isinstance(item, dict):
            raise ValueError(f"非法 Kimi hook 条目: {item!r}")
        event = item.get("event")
        matcher = item.get("matcher")
        if event == "SessionStart":
            continue
        if event == "PreToolUse" and matcher == "Grep|Glob":
            continue
        gate = kimi_gate(str(item.get("command", "")))
        if gate is None:
            raise ValueError(
                f"无法解析阻断 Hook event={event} matcher={matcher} "
                f"command={item.get('command')}"
            )
        contracts[(str(event), str(matcher), gate)] += 1
    return contracts


def normalized_contracts(
    config: object,
    hook_keys: tuple[str, ...],
    command_parser: CommandParser,
) -> Counter[Contract]:
    hooks = config
    for key in hook_keys:
        hooks = hooks[key]  # type: ignore[index]

    contracts: Counter[Contract] = Counter()
    for event, items in hooks.items():  # type: ignore[union-attr]
        if event == "SessionStart":
            continue
        for item in items:
            matcher = item.get("matcher")
            if event == "PreToolUse" and matcher == "Grep|Glob":
                continue
            for hook in item.get("hooks", []):
                if hook.get("type") != "command":
                    raise ValueError(
                        f"无法解析阻断 Hook event={event} matcher={matcher} "
                        f"type={hook.get('type')}"
                    )
                command = hook.get("command", "")
                gate = command_parser(command)
                if gate is None:
                    raise ValueError(
                        f"无法解析阻断 Hook event={event} matcher={matcher} "
                        f"command={command}"
                    )
                contracts[(event, matcher, gate)] += 1
    return contracts


def parse_args() -> argparse.Namespace:
    root = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser()
    parser.add_argument("--zcode", type=Path, default=root / ".zcode/config.json")
    parser.add_argument("--claude", type=Path, default=root / ".claude/settings.json")
    parser.add_argument("--codex", type=Path, default=root / ".codex/hooks.json")
    parser.add_argument("--kimi", type=Path, default=root / ".kimi-code/hooks.toml")
    parser.add_argument("--hooks-dir", type=Path, default=root / ".claude/hooks")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    platforms = (
        ("ZCode", args.zcode, ("hooks", "events"), claude_gate),
        ("Claude Code", args.claude, ("hooks",), claude_gate),
        ("Codex", args.codex, ("hooks",), codex_gate),
    )
    expected = Counter(EXPECTED_CONTRACTS)
    runtime_pretool_gates = {
        gate for event, _matcher, gate in EXPECTED_CONTRACTS if event == "PreToolUse"
    }

    failed = False

    def compare(platform: str, actual: Counter[Contract]) -> None:
        nonlocal failed
        for (event, matcher, gate), expected_count in expected.items():
            actual_count = actual[(event, matcher, gate)]
            if actual_count < expected_count:
                print(
                    f"{platform}: 缺失 Hook 契约 "
                    f"event={event} matcher={matcher} gate={gate} "
                    f"expected_count={expected_count} actual_count={actual_count}",
                    file=sys.stderr,
                )
                failed = True
            elif actual_count > expected_count:
                print(
                    f"{platform}: 重复 Hook 契约 "
                    f"event={event} matcher={matcher} gate={gate} "
                    f"expected_count={expected_count} actual_count={actual_count}",
                    file=sys.stderr,
                )
                failed = True

        for event, matcher, gate in sorted(actual.keys() - expected.keys()):
            print(
                f"{platform}: 多余 Hook 契约 "
                f"event={event} matcher={matcher} gate={gate} "
                f"expected_count=0 actual_count={actual[(event, matcher, gate)]}",
                file=sys.stderr,
            )
            failed = True

    for platform, path, hook_keys, command_parser in platforms:
        try:
            config = json.loads(path.read_text())
            actual = normalized_contracts(config, hook_keys, command_parser)
        except (OSError, json.JSONDecodeError, KeyError, TypeError, ValueError, AttributeError) as error:
            print(f"{platform}: 无法解析 Hook 配置 {path}: {error}", file=sys.stderr)
            failed = True
            continue

        runtime_pretool_gates.update(
            gate for event, _matcher, gate in actual if event == "PreToolUse"
        )
        compare(platform, actual)

    try:
        import tomllib
    except ModuleNotFoundError:
        print("Kimi CLI: 需要 Python 3.11+ tomllib 解析 .kimi-code/hooks.toml", file=sys.stderr)
        failed = True
    else:
        try:
            with args.kimi.open("rb") as kimi_file:
                kimi_config = tomllib.load(kimi_file)
            kimi_actual = kimi_normalized_contracts(kimi_config)
        except (OSError, tomllib.TOMLDecodeError, KeyError, TypeError, ValueError, AttributeError) as error:
            print(f"Kimi CLI: 无法解析 Hook 配置 {args.kimi}: {error}", file=sys.stderr)
            failed = True
        else:
            runtime_pretool_gates.update(
                gate for event, _matcher, gate in kimi_actual if event == "PreToolUse"
            )
            compare("Kimi CLI", kimi_actual)

    for gate in sorted(runtime_pretool_gates):
        path = args.hooks_dir / gate
        try:
            source = path.read_text()
        except OSError as error:
            print(f"审计覆盖检查: 无法读取运行时 Gate {path}: {error}", file=sys.stderr)
            failed = True
            continue
        if "lib/hook_audit.py" not in source or "--operation" not in source:
            print(
                f"审计覆盖检查: 运行时阻断型 PreToolUse Gate 未接入共享审计器 gate={gate}",
                file=sys.stderr,
            )
            failed = True

    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
