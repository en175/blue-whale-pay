#!/usr/bin/env python3
"""Verify preflight-to-Gate-to-audit closure through real platform configs."""

from __future__ import annotations

import argparse
import json
import os
import shlex
import shutil
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
QUERY_SCRIPT = REPO_ROOT / "scripts" / "query-hook-audit.py"
KIMI_SHIM_SRC = REPO_ROOT / ".kimi-code" / "hooks" / "blue-whale-hook.sh"
TASK_BRANCH = "feature/ik10dx-audit"


class VerificationError(RuntimeError):
    def __init__(self, platform: str, stage: str, detail: str):
        super().__init__(detail)
        self.platform = platform
        self.stage = stage
        self.detail = detail


@dataclass(frozen=True)
class Platform:
    name: str
    slug: str
    config_path: Path
    hook_keys: tuple[str, ...]
    codex: bool = False
    kimi: bool = False


@dataclass(frozen=True)
class ConfigChain:
    platform: Platform
    matcher: str
    command: str
    gate: str


PLATFORMS = (
    Platform("ZCode", "zcode", REPO_ROOT / ".zcode/config.json", ("hooks", "events")),
    Platform(
        "Claude Code",
        "claude-code",
        REPO_ROOT / ".claude/settings.json",
        ("hooks",),
    ),
    Platform(
        "Codex",
        "codex",
        REPO_ROOT / ".codex/hooks.json",
        ("hooks",),
        codex=True,
    ),
    Platform(
        "Kimi CLI",
        "kimi",
        REPO_ROOT / ".kimi-code" / "hooks.toml",
        (),
        kimi=True,
    ),
)


def fail(platform: str, stage: str, detail: str) -> None:
    raise VerificationError(platform, stage, detail)


def run_git(repo: Path, *args: str) -> str:
    result = subprocess.run(
        ["git", "-C", str(repo), *args], capture_output=True, text=True
    )
    if result.returncode != 0:
        fail("shared", "fixture", result.stderr.strip() or "Git 命令失败")
    return result.stdout.strip()


def load_chain(platform: Platform) -> ConfigChain:
    if platform.kimi:
        return load_kimi_chain(platform)
    try:
        hooks = json.loads(platform.config_path.read_text(encoding="utf-8"))
        for key in platform.hook_keys:
            hooks = hooks[key]
        items = [
            item
            for item in hooks["PreToolUse"]
            if item.get("matcher") == "Edit|Write"
        ]
    except (OSError, json.JSONDecodeError, KeyError, TypeError) as exc:
        fail(platform.name, "config-parse", f"无法解析真实配置 {platform.config_path}: {exc}")
    if len(items) != 1:
        fail(
            platform.name,
            "matcher",
            f"matcher=Edit|Write expected_count=1 actual_count={len(items)}",
        )
    command_hooks = [
        hook for hook in items[0].get("hooks", []) if hook.get("type") == "command"
    ]
    if len(command_hooks) != 1:
        fail(
            platform.name,
            "command",
            f"command hook expected_count=1 actual_count={len(command_hooks)}",
        )
    command = command_hooks[0].get("command", "")
    try:
        parts = shlex.split(command)
    except ValueError as exc:
        fail(platform.name, "command", f"执行命令无法解析: {exc}")
    gates = [
        Path(part).name
        for part in parts
        if part.endswith(".sh") and Path(part).name != "run-claude-pretool.sh"
    ]
    if len(gates) != 1:
        fail(platform.name, "gate", f"权威 Gate 无法唯一解析: command={command!r}")
    return ConfigChain(platform, "Edit|Write", command, gates[0])


def load_kimi_chain(platform: Platform) -> ConfigChain:
    """Load the Kimi CLI chain from the TOML snippet ([[hooks]] flat list)."""
    try:
        import tomllib
    except ModuleNotFoundError:
        fail(platform.name, "config-parse", "需要 Python 3.11+ tomllib 解析 .kimi-code/hooks.toml")
    try:
        with platform.config_path.open("rb") as config_file:
            config = tomllib.load(config_file)
        items = [
            item
            for item in config.get("hooks", [])
            if item.get("event") == "PreToolUse" and item.get("matcher") == "Edit|Write"
        ]
    except (OSError, tomllib.TOMLDecodeError, AttributeError, TypeError) as exc:
        fail(platform.name, "config-parse", f"无法解析真实配置 {platform.config_path}: {exc}")
    if len(items) != 1:
        fail(
            platform.name,
            "matcher",
            f"matcher=Edit|Write expected_count=1 actual_count={len(items)}",
        )
    command = str(items[0].get("command", ""))
    try:
        parts = shlex.split(command)
    except ValueError as exc:
        fail(platform.name, "command", f"执行命令无法解析: {exc}")
    gates = [
        Path(part).name
        for part in parts
        if part.endswith(".sh") and Path(part).name != "blue-whale-hook.sh"
    ]
    if len(gates) != 1:
        fail(platform.name, "gate", f"权威 Gate 无法唯一解析: command={command!r}")
    return ConfigChain(platform, "Edit|Write", command, gates[0])


def setup_fixture(root: Path, platforms: tuple[Platform, ...]) -> tuple[Path, Path]:
    master = root / "master"
    task = root / "task"
    subprocess.run(
        ["git", "init", "--initial-branch=master", str(master)],
        check=True,
        capture_output=True,
        text=True,
    )
    run_git(master, "config", "user.name", "Hook Closed Loop")
    run_git(master, "config", "user.email", "hook-closed-loop@example.com")
    for platform in platforms:
        (master / f"existing-{platform.slug}.txt").write_text(
            "before\n", encoding="utf-8"
        )
    run_git(master, "add", ".")
    run_git(master, "commit", "-m", "test: initialize Hook closure fixture")
    run_git(master, "worktree", "add", "-b", TASK_BRANCH, str(task))
    return master, task


def native_input(
    chain: ConfigChain,
    area: str,
    operation: str,
    cwd: Path,
    tool_use_id: str,
    session_id: str,
) -> tuple[dict[str, object], Path, str]:
    if operation == "create":
        target = cwd / f"created-{chain.platform.slug}-{area}.txt"
    else:
        target = cwd / f"existing-{chain.platform.slug}.txt"
    if chain.platform.codex:
        marker = "Add" if operation == "create" else "Update"
        patch = (
            "*** Begin Patch\n"
            f"*** {marker} File: {target.name}\n"
            "+created\n"
            "*** End Patch"
        )
        return (
            {
                "tool_name": "apply_patch",
                "cwd": str(cwd),
                "session_id": session_id,
                "tool_use_id": tool_use_id,
                "tool_input": {"command": patch},
            },
            target,
            "Write",
        )
    if chain.platform.kimi:
        # Kimi CLI 0.26 实测载荷：关联 id 字段是 tool_call_id（无 tool_use_id），
        # Write/Edit 目标路径参数是 path（无 file_path）。
        tool = "Write" if operation == "create" else "Edit"
        return (
            {
                "hook_event_name": "PreToolUse",
                "tool_name": tool,
                "session_id": session_id,
                "cwd": str(cwd),
                "tool_call_id": tool_use_id,
                "tool_input": {"path": str(target)},
            },
            target,
            tool,
        )
    tool = "Write" if operation == "create" else "Edit"
    return (
        {
            "tool_name": tool,
            "session_id": session_id,
            "tool_use_id": tool_use_id,
            "tool_input": {"file_path": str(target)},
        },
        target,
        tool,
    )


def execute(
    chain: ConfigChain,
    payload: dict[str, object],
    env_extra: dict[str, str] | None = None,
) -> subprocess.CompletedProcess[str]:
    env = os.environ.copy()
    env["CLAUDE_PROJECT_DIR"] = str(REPO_ROOT)
    if env_extra:
        env.update(env_extra)
    return subprocess.run(
        chain.command,
        cwd=str(REPO_ROOT),
        env=env,
        input=json.dumps(payload, ensure_ascii=False),
        capture_output=True,
        text=True,
        shell=True,
        executable="/bin/bash",
    )


def query(project_dir: Path, *args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, str(QUERY_SCRIPT), "--project-dir", str(project_dir), *args],
        capture_output=True,
        text=True,
    )


def unique_record(master: Path, chain: ConfigChain, tool_use_id: str) -> dict[str, object]:
    result = query(master, "--tool-use-id", tool_use_id)
    if result.returncode != 0:
        fail(chain.platform.name, "audit-query", result.stderr.strip())
    lines = [line for line in result.stdout.splitlines() if line]
    if lines == ["未进入仓库 Hook 执行链"]:
        fail(chain.platform.name, "audit-correlation", lines[0])
    if len(lines) != 1:
        fail(
            chain.platform.name,
            "audit-uniqueness",
            f"tool_use_id={tool_use_id} expected_count=1 actual_count={len(lines)}",
        )
    try:
        record = json.loads(lines[0])
    except json.JSONDecodeError as exc:
        fail(chain.platform.name, "audit-query", f"返回非 JSON 记录: {exc}")
    return record


def check_record(
    chain: ConfigChain,
    record: dict[str, object],
    expected: dict[str, object],
) -> None:
    for field, value in expected.items():
        if record.get(field) != value:
            fail(
                chain.platform.name,
                "audit-fields",
                f"field={field} expected={value!r} actual={record.get(field)!r}",
            )


def verify(platforms: tuple[Platform, ...]) -> None:
    chains = tuple(load_chain(platform) for platform in platforms)
    gates = {chain.gate for chain in chains}
    if len(gates) != 1:
        mapping = " ".join(
            f"{chain.platform.name}={chain.gate}" for chain in chains
        )
        fail("shared", "gate", f"各平台未到达同一权威 Gate: {mapping}")
    gate = next(iter(gates))

    expected_ids: set[str] = set()
    with tempfile.TemporaryDirectory() as temp:
        master, task = setup_fixture(Path(temp), platforms)
        # Kimi CLI shim 安装到临时 HOME：command 中的 $HOME 指向它，
        # shim 再按会话 cwd(REPO_ROOT) 的 opt-in 标记路由到权威 Gate。
        kimi_home = Path(temp) / "kimi-home"
        if any(platform.kimi for platform in platforms):
            shim_dst = kimi_home / ".kimi-code" / "hooks" / "blue-whale-hook.sh"
            shim_dst.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy(KIMI_SHIM_SRC, shim_dst)
        for chain in chains:
            session_id = f"ik10dx-{chain.platform.slug}"
            env_extra = {"HOME": str(kimi_home)} if chain.platform.kimi else None
            for area, cwd, exit_code, branch, reason in (
                ("master", master, 2, "master", "blocked-master"),
                ("task", task, 0, TASK_BRANCH, "allowed-non-master"),
            ):
                for operation in ("create", "update"):
                    tool_use_id = f"{session_id}-{area}-{operation}"
                    expected_ids.add(tool_use_id)
                    payload, target, normalized_tool = native_input(
                        chain, area, operation, cwd, tool_use_id, session_id
                    )
                    result = execute(chain, payload, env_extra)
                    if result.returncode != exit_code:
                        fail(
                            chain.platform.name,
                            f"execute-{area}-{operation}",
                            f"expected_exit={exit_code} actual_exit={result.returncode} "
                            f"stdout={result.stdout!r} stderr={result.stderr!r}",
                        )
                    if result.stdout:
                        fail(
                            chain.platform.name,
                            f"execute-{area}-{operation}",
                            f"stdout 应为空，actual={result.stdout!r}",
                        )
                    if exit_code == 2 and "BLOCKED:" not in result.stderr:
                        fail(
                            chain.platform.name,
                            f"execute-{area}-{operation}",
                            f"阻断原因缺失，stderr={result.stderr!r}",
                        )
                    if exit_code == 0 and result.stderr:
                        fail(
                            chain.platform.name,
                            f"execute-{area}-{operation}",
                            f"放行 stderr 应为空，actual={result.stderr!r}",
                        )
                    record = unique_record(master, chain, tool_use_id)
                    check_record(
                        chain,
                        record,
                        {
                            "hook": gate,
                            "tool": normalized_tool,
                            "file_path": str(target),
                            "branch": branch,
                            "operation": "file-write",
                            "session_id": session_id,
                            "tool_use_id": tool_use_id,
                            "exit_code": exit_code,
                            "reason": reason,
                        },
                    )

        all_records = query(master)
        if all_records.returncode != 0:
            fail("shared", "audit-query", all_records.stderr.strip())
        records = [json.loads(line) for line in all_records.stdout.splitlines() if line]
        actual_ids = [record.get("tool_use_id") for record in records]
        if len(records) != len(expected_ids) or set(actual_ids) != expected_ids:
            fail(
                "shared",
                "audit-isolation",
                f"expected_ids={sorted(expected_ids)} actual_ids={actual_ids}",
            )

        missing = query(master, "--tool-use-id", "ik10dx-missing")
        if missing.returncode != 0 or missing.stdout != "未进入仓库 Hook 执行链\n":
            fail(
                "shared",
                "missing-id-diagnostic",
                f"stdout={missing.stdout!r} stderr={missing.stderr!r}",
            )

    print("[直接 Gate 黑盒] 由 scripts/test-hooks.sh 覆盖；本检查器不重复冒充客户端调用。")
    for chain in chains:
        print(
            f"[配置链集成] {chain.platform.name} matcher={chain.matcher} "
            f"gate={chain.gate} master=create/update blocked task=create/update allowed"
        )
    print(
        f"[配置链集成] audit={len(expected_ids)}/{len(expected_ids)} unique correlated records; "
        "missing-id diagnostic=passed"
    )
    print(
        "[外部客户端实机探针] 未执行；需在 ZCode、Claude Code、Codex 或 Kimi CLI 客户端环境单独取证，"
        "不得由本地 Gate/配置链结果推断。"
    )


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--zcode", type=Path, default=PLATFORMS[0].config_path)
    parser.add_argument("--claude", type=Path, default=PLATFORMS[1].config_path)
    parser.add_argument("--codex", type=Path, default=PLATFORMS[2].config_path)
    parser.add_argument("--kimi", type=Path, default=PLATFORMS[3].config_path)
    return parser.parse_args(argv)


def configured_platforms(args: argparse.Namespace) -> tuple[Platform, ...]:
    return (
        Platform("ZCode", "zcode", args.zcode, ("hooks", "events")),
        Platform("Claude Code", "claude-code", args.claude, ("hooks",)),
        Platform("Codex", "codex", args.codex, ("hooks",), codex=True),
        Platform("Kimi CLI", "kimi", args.kimi, (), kimi=True),
    )


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv or sys.argv[1:])
    try:
        verify(configured_platforms(args))
        return 0
    except VerificationError as exc:
        print(
            f"配置链闭环失败: platform={exc.platform} stage={exc.stage} "
            f"reason={exc.detail}",
            file=sys.stderr,
        )
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
