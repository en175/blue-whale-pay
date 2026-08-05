#!/usr/bin/env python3
"""Synchronize a task worktree with origin/master as a recoverable transaction."""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
import time
from pathlib import Path

from sync_recovery import RecoveryError, load_recovery, write_recovery


RECOVERY_FILE = "agent-sync-recovery.json"
BACKUP_PREFIX = "refs/agent-sync-backups/"


class WorkflowError(RuntimeError):
    pass


def git(root: Path, *args: str, check: bool = True) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["git", "-C", str(root), *args],
        text=True,
        capture_output=True,
        check=check,
    )


def git_output(root: Path, *args: str) -> str:
    return git(root, *args).stdout.strip()


def repository_root() -> Path:
    result = subprocess.run(
        ["git", "rev-parse", "--show-toplevel"],
        text=True,
        capture_output=True,
    )
    if result.returncode != 0:
        raise WorkflowError("当前目录不在 Git 仓库中。")
    return Path(result.stdout.strip()).resolve()


def absolute_git_path(root: Path, argument: str) -> Path:
    value = git_output(root, "rev-parse", argument)
    path = Path(value)
    return path if path.is_absolute() else (root / path).resolve()


def worktree_context(root: Path) -> tuple[Path, str]:
    git_dir = absolute_git_path(root, "--absolute-git-dir")
    common_dir = absolute_git_path(root, "--git-common-dir")
    if git_dir == common_dir:
        raise WorkflowError("同步入口只能在 task worktree 中执行，禁止在主 checkout 运行。")
    branch = git_output(root, "symbolic-ref", "--short", "HEAD")
    validator = Path(__file__).with_name("start-task-worktree.py")
    validation = subprocess.run(
        [sys.executable, str(validator), "--validate-branch", branch],
        text=True,
        capture_output=True,
    )
    if validation.returncode != 0:
        detail = validation.stderr.strip() or validation.stdout.strip()
        raise WorkflowError("当前分支不是结构化任务分支：{}；{}".format(branch, detail))
    return git_dir, branch


def ensure_clean(root: Path) -> None:
    if git_output(root, "status", "--porcelain"):
        raise WorkflowError("工作区不干净；同步或恢复前请先提交或处理改动。")


def ensure_no_git_operation(git_dir: Path) -> None:
    names = ("MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD", "rebase-merge", "rebase-apply")
    active = [name for name in names if (git_dir / name).exists()]
    if active:
        raise WorkflowError("检测到进行中的 Git 操作：{}".format(", ".join(active)))


def recovery_paths(git_dir: Path, branch: str) -> tuple[Path, str]:
    return git_dir / RECOVERY_FILE, BACKUP_PREFIX + branch.replace("/", "%")


def read_recovery(path: Path, branch: str) -> dict[str, object]:
    if not path.exists():
        raise WorkflowError("当前 worktree 没有可用的同步恢复点。")
    try:
        payload = load_recovery(path)
    except RecoveryError as exc:
        raise WorkflowError("同步恢复点无法读取：{}".format(exc)) from exc
    if payload.get("branch") != branch:
        raise WorkflowError("同步恢复点属于其他分支，拒绝使用。")
    return payload


def remote_branch_sha(root: Path, branch: str) -> str:
    result = git(root, "ls-remote", "--heads", "origin", "refs/heads/{}".format(branch), check=False)
    if result.returncode != 0:
        raise WorkflowError("无法读取远端源分支状态：{}".format(result.stderr.strip()))
    return result.stdout.split()[0] if result.stdout.strip() else ""


def remove_recovery(root: Path, marker: Path, backup_ref: str) -> None:
    deleted = git(root, "update-ref", "-d", backup_ref, check=False)
    if deleted.returncode != 0:
        raise WorkflowError(
            "无法删除同步 backup ref，恢复记录已保留：{}".format(
                deleted.stderr.strip() or deleted.stdout.strip()
            )
        )
    marker.unlink(missing_ok=True)


def emit(as_json: bool, status: str, **details: object) -> None:
    payload = {"status": status, **details}
    if as_json:
        print(json.dumps(payload, ensure_ascii=False, sort_keys=True))
    else:
        print("{}: {}".format(status, json.dumps(details, ensure_ascii=False, sort_keys=True)))


def synchronize(root: Path, as_json: bool) -> int:
    git_dir, branch = worktree_context(root)
    ensure_clean(root)
    ensure_no_git_operation(git_dir)
    fetch = git(root, "fetch", "origin", "master", check=False)
    if fetch.returncode != 0:
        raise WorkflowError("fetch origin master 失败：{}".format(fetch.stderr.strip()))

    upstream_sha = git_output(root, "rev-parse", "origin/master")
    original_head = git_output(root, "rev-parse", "HEAD")
    marker, backup_ref = recovery_paths(git_dir, branch)
    if git(root, "merge-base", "--is-ancestor", upstream_sha, original_head, check=False).returncode == 0:
        emit(
            as_json,
            "UP_TO_DATE",
            branch=branch,
            head=original_head,
            upstream_sha=upstream_sha,
            recovery_available=marker.exists(),
        )
        return 0

    if marker.exists():
        recovery = read_recovery(marker, branch)
        if recovery.get("pushed_head"):
            raise WorkflowError("上一轮同步结果已经推送；完成远端核验并 finalize 后才能开启新事务。")
        expected_head = str(recovery.get("synced_head", recovery["original_head"]))
        if original_head != expected_head:
            raise WorkflowError("当前 HEAD 已离开已有同步事务，拒绝覆盖恢复点。")
        backup_ref = str(recovery.get("backup_ref", backup_ref))
        remote_sha = str(recovery.get("remote_branch_sha", ""))
        recovery["upstream_sha"] = upstream_sha
    else:
        remote_sha = remote_branch_sha(root, branch)
        git(root, "update-ref", backup_ref, original_head)
        recovery = {
            "version": 1,
            "branch": branch,
            "original_head": original_head,
            "upstream_sha": upstream_sha,
            "remote_branch_sha": remote_sha,
            "backup_ref": backup_ref,
            "created_at": int(time.time()),
        }
    write_recovery(marker, recovery)

    rebase = git(root, "rebase", "origin/master", check=False)
    if rebase.returncode != 0:
        conflicts = git_output(root, "diff", "--name-only", "--diff-filter=U").splitlines()
        rebase_head_probe = git(root, "rev-parse", "--verify", "REBASE_HEAD", check=False)
        rebase_head = rebase_head_probe.stdout.strip() if rebase_head_probe.returncode == 0 else ""
        abort = git(root, "rebase", "--abort", check=False)
        restored_head = git_output(root, "rev-parse", "HEAD")
        if abort.returncode != 0 or restored_head != original_head:
            raise WorkflowError(
                "rebase 冲突且自动 abort 未能恢复原 HEAD；abort 输出：{}".format(abort.stderr.strip())
            )
        emit(
            as_json,
            "REBASE_CONFLICT_ABORTED",
            branch=branch,
            original_head=original_head,
            upstream_sha=upstream_sha,
            remote_branch_sha=remote_sha,
            replaying_commit=rebase_head,
            conflict_files=conflicts,
            recovery_file=str(marker),
            backup_ref=backup_ref,
        )
        return 3

    synced_head = git_output(root, "rev-parse", "HEAD")
    recovery["synced_head"] = synced_head
    write_recovery(marker, recovery)
    diff_check = git(root, "diff", "--check", "origin/master...HEAD", check=False)
    if diff_check.returncode != 0:
        emit(
            as_json,
            "VERIFICATION_FAILED",
            branch=branch,
            head=synced_head,
            recovery_file=str(marker),
            detail=diff_check.stdout.strip() or diff_check.stderr.strip(),
        )
        return 4
    emit(
        as_json,
        "SYNCED",
        branch=branch,
        original_head=original_head,
        head=synced_head,
        upstream_sha=upstream_sha,
        remote_branch_sha=remote_sha,
        recovery_file=str(marker),
        backup_ref=backup_ref,
    )
    return 0


def rollback(root: Path, as_json: bool) -> int:
    git_dir, branch = worktree_context(root)
    ensure_clean(root)
    ensure_no_git_operation(git_dir)
    marker, backup_ref = recovery_paths(git_dir, branch)
    recovery = read_recovery(marker, branch)
    if recovery.get("pushed_head") or recovery.get("push_state"):
        raise WorkflowError("同步后的 HEAD 已进入推送阶段；禁止自动 rollback，请先完成远端核验与人工决策。")
    original_head = str(recovery["original_head"])
    current_head = git_output(root, "rev-parse", "HEAD")
    synced_head = str(recovery.get("synced_head", original_head))
    if current_head not in {original_head, synced_head}:
        raise WorkflowError("当前 HEAD 已离开同步事务，拒绝自动 rollback。")
    if current_head != original_head:
        reset = git(root, "reset", "--keep", original_head, check=False)
        if reset.returncode != 0:
            raise WorkflowError("rollback 失败：{}".format(reset.stderr.strip()))
    remove_recovery(root, marker, backup_ref)
    emit(as_json, "ROLLED_BACK", branch=branch, head=original_head)
    return 0


def finalize(root: Path, as_json: bool) -> int:
    git_dir, branch = worktree_context(root)
    ensure_clean(root)
    ensure_no_git_operation(git_dir)
    marker, backup_ref = recovery_paths(git_dir, branch)
    recovery = read_recovery(marker, branch)
    current_head = git_output(root, "rev-parse", "HEAD")
    if recovery.get("push_state") != "pushed" or recovery.get("pushed_head") != current_head:
        raise WorkflowError("同步事务尚未推送当前 HEAD，禁止 finalize。")
    if recovery.get("verified_head") != current_head:
        raise WorkflowError("当前 HEAD 尚未通过 Gitee PR 远端核验，禁止 finalize。")
    remove_recovery(root, marker, str(recovery.get("backup_ref", backup_ref)))
    emit(as_json, "FINALIZED", branch=branch, head=current_head)
    return 0


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("sync", "rollback", "finalize"))
    parser.add_argument("--json", action="store_true", dest="as_json")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv or sys.argv[1:])
    try:
        root = repository_root()
        if args.action == "sync":
            return synchronize(root, args.as_json)
        if args.action == "rollback":
            return rollback(root, args.as_json)
        return finalize(root, args.as_json)
    except (RecoveryError, WorkflowError, subprocess.CalledProcessError) as exc:
        emit(args.as_json, "ERROR", detail=str(exc))
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
