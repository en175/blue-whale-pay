#!/usr/bin/env python3
"""Machine-verifiable, one-shot authorizations for high-impact Agent actions."""

from __future__ import annotations

import os
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass
from pathlib import Path


VERSION = "1"
TTL_SECONDS = 900
MARKER_DIR = "agent-action-authorizations"
FIELDS = ("version", "action", "enterprise_id", "project_id", "subject", "created_at")
CLAIM_FIELDS = ("tool_use_id", "claimed_at")


@dataclass(frozen=True)
class AuthorizationScope:
    action: str
    enterprise_id: str
    project_id: str
    subject: str

    def payload(self) -> bytes:
        return f"{self.action}\n{self.enterprise_id}\n{self.project_id}\n{self.subject}\n".encode()

    def expected_values(self) -> dict[str, str]:
        return {
            "version": VERSION,
            "action": self.action,
            "enterprise_id": self.enterprise_id,
            "project_id": self.project_id,
            "subject": self.subject,
        }


def fail(message: str, code: int = 2) -> int:
    print(message, file=sys.stderr)
    return code


def git_common_dir(project_dir: str) -> Path:
    root = Path(project_dir).resolve()
    result = subprocess.run(
        ["git", "-C", str(root), "rev-parse", "--git-common-dir"],
        check=True,
        capture_output=True,
        text=True,
    )
    common = Path(result.stdout.strip())
    return common if common.is_absolute() else root / common


def scope_digest(project_dir: str, scope: AuthorizationScope) -> str:
    result = subprocess.run(
        ["git", "-C", project_dir, "hash-object", "--stdin"],
        input=scope.payload(),
        check=True,
        capture_output=True,
    )
    return result.stdout.decode().strip()


def marker_path(project_dir: str, scope: AuthorizationScope) -> Path:
    digest = scope_digest(project_dir, scope)
    return git_common_dir(project_dir) / MARKER_DIR / digest


def claim_path(project_dir: str, scope: AuthorizationScope) -> Path:
    marker = marker_path(project_dir, scope)
    return marker.with_name(f"{marker.name}.claim")


def remove_scope_files(project_dir: str, scope: AuthorizationScope) -> None:
    claim_path(project_dir, scope).unlink(missing_ok=True)
    marker_path(project_dir, scope).unlink(missing_ok=True)


def parse_marker(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        if "=" not in line:
            raise ValueError("凭证格式无效")
        key, value = line.split("=", 1)
        if key not in FIELDS or key in values:
            raise ValueError("凭证字段无效")
        values[key] = value
    if tuple(values) != FIELDS:
        raise ValueError("凭证字段不完整或顺序错误")
    return values


def parse_claim(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        if "=" not in line:
            raise ValueError("占用记录格式无效")
        key, value = line.split("=", 1)
        if key not in CLAIM_FIELDS or key in values:
            raise ValueError("占用记录字段无效")
        values[key] = value
    if tuple(values) != CLAIM_FIELDS:
        raise ValueError("占用记录字段不完整或顺序错误")
    return values


def grant(project_dir: str, scope: AuthorizationScope) -> int:
    path = marker_path(project_dir, scope)
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    values = scope.expected_values()
    values["created_at"] = str(int(time.time()))
    fd, tmp_name = tempfile.mkstemp(prefix=".authorization-", dir=path.parent)
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            for key in FIELDS:
                handle.write(f"{key}={values[key]}\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(tmp_name, path)
        os.chmod(path, 0o600)
        claim_path(project_dir, scope).unlink(missing_ok=True)
    finally:
        if os.path.exists(tmp_name):
            os.unlink(tmp_name)
    print(f"已生成一次性授权凭证：{scope.action} {scope.subject}")
    return 0


def validate(project_dir: str, scope: AuthorizationScope) -> int:
    path = marker_path(project_dir, scope)
    if not path.is_file():
        return fail("缺少匹配的一次性授权凭证。")
    try:
        values = parse_marker(path)
    except (OSError, ValueError) as error:
        remove_scope_files(project_dir, scope)
        return fail(f"一次性授权凭证无效：{error}。")
    expected = scope.expected_values()
    if any(values.get(key) != value for key, value in expected.items()):
        remove_scope_files(project_dir, scope)
        return fail("一次性授权凭证与当前操作不匹配。")
    try:
        created_at = int(values["created_at"])
    except ValueError:
        remove_scope_files(project_dir, scope)
        return fail("一次性授权凭证时间无效。")
    age = int(time.time()) - created_at
    if age < 0 or age > TTL_SECONDS:
        remove_scope_files(project_dir, scope)
        return fail("一次性授权凭证已过期。")
    return 0


def claim(project_dir: str, scope: AuthorizationScope, tool_use_id: str) -> int:
    if not tool_use_id or "\n" in tool_use_id or "\r" in tool_use_id:
        return fail("tool_use_id 无效。")
    if validate(project_dir, scope) != 0:
        return 2
    path = claim_path(project_dir, scope)
    now = int(time.time())
    for _ in range(2):
        try:
            fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        except FileExistsError:
            try:
                values = parse_claim(path)
                claimed_at = int(values["claimed_at"])
            except (OSError, ValueError):
                path.unlink(missing_ok=True)
                continue
            if values["tool_use_id"] == tool_use_id:
                return 0
            if claimed_at > now or now - claimed_at > TTL_SECONDS:
                path.unlink(missing_ok=True)
                continue
            return fail("一次性授权凭证已被另一个工具调用占用。")
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(f"tool_use_id={tool_use_id}\nclaimed_at={now}\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(path, 0o600)
        return 0
    return fail("无法原子占用一次性授权凭证。")


def claim_owned_by(project_dir: str, scope: AuthorizationScope, tool_use_id: str) -> bool:
    try:
        values = parse_claim(claim_path(project_dir, scope))
    except (OSError, ValueError):
        return False
    return values.get("tool_use_id") == tool_use_id


def release(project_dir: str, scope: AuthorizationScope, tool_use_id: str) -> int:
    path = claim_path(project_dir, scope)
    if not path.exists():
        return 0
    if not claim_owned_by(project_dir, scope, tool_use_id):
        return fail("工具调用与凭证占用记录不匹配。")
    path.unlink(missing_ok=True)
    return 0


def consume(project_dir: str, scope: AuthorizationScope, tool_use_id: str) -> int:
    if not claim_owned_by(project_dir, scope, tool_use_id):
        return fail("工具调用未持有该一次性授权凭证。")
    remove_scope_files(project_dir, scope)
    return 0


def revoke_all(project_dir: str) -> int:
    directory = git_common_dir(project_dir) / MARKER_DIR
    if directory.is_dir():
        for path in directory.iterdir():
            if path.is_file() or path.is_symlink():
                path.unlink()
        try:
            directory.rmdir()
        except OSError:
            pass
    print("已撤销全部未消费授权凭证。")
    return 0


def main() -> int:
    if len(sys.argv) < 3:
        return fail("用法错误。")
    mode = sys.argv[1]
    if mode == "grant":
        if len(sys.argv) != 8 or sys.argv[2] != "--user-authorized":
            return fail("grant 缺少 --user-authorized。")
        project_dir = sys.argv[3]
        scope_args = sys.argv[4:]
    else:
        project_dir = sys.argv[2]
        scope_args = sys.argv[3:]
    if mode == "revoke-all" and len(sys.argv) == 3:
        return revoke_all(project_dir)
    modes_without_tool_id = {"grant", "validate", "revoke"}
    modes_with_tool_id = {"claim", "consume", "release"}
    if mode in modes_without_tool_id and len(scope_args) != 4:
        return fail("用法错误。")
    if mode in modes_with_tool_id and len(scope_args) != 5:
        return fail("用法错误。")
    if mode not in modes_without_tool_id | modes_with_tool_id:
        return fail("用法错误。")
    scope = AuthorizationScope(*scope_args[:4])
    tool_use_id = scope_args[4] if len(scope_args) == 5 else ""
    if mode == "grant":
        return grant(project_dir, scope)
    if mode == "validate":
        return validate(project_dir, scope)
    if mode == "claim":
        return claim(project_dir, scope, tool_use_id)
    if mode == "consume":
        return consume(project_dir, scope, tool_use_id)
    if mode == "release":
        return release(project_dir, scope, tool_use_id)
    if mode == "revoke":
        remove_scope_files(project_dir, scope)
        print(f"已撤销一次性授权凭证：{scope.action} {scope.subject}")
        return 0
    return fail("未知模式。")


if __name__ == "__main__":
    raise SystemExit(main())
