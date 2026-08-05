#!/usr/bin/env python3
"""Black-box tests for the task-branch synchronization transaction."""

from __future__ import annotations

import json
import subprocess
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
SYNC_SCRIPT = REPO_ROOT / "scripts" / "sync-task-from-origin.sh"


def run(*args: str, cwd: Path, check: bool = False) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        list(args),
        cwd=cwd,
        text=True,
        capture_output=True,
        check=check,
    )


class SyncTaskFromOriginTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tempdir = tempfile.TemporaryDirectory()
        self.root = Path(self.tempdir.name)
        self.origin = self.root / "origin.git"
        self.main = self.root / "main"
        self.worktree = self.root / "blue-whale-worktrees" / "feature-test"

        run("git", "init", "--bare", str(self.origin), cwd=self.root, check=True)
        run("git", "init", str(self.main), cwd=self.root, check=True)
        run("git", "config", "user.name", "Test User", cwd=self.main, check=True)
        run("git", "config", "user.email", "test@example.com", cwd=self.main, check=True)
        run("git", "config", "commit.gpgsign", "false", cwd=self.main, check=True)
        (self.main / "shared.txt").write_text("base\n", encoding="utf-8")
        run("git", "add", "shared.txt", cwd=self.main, check=True)
        run("git", "commit", "-m", "chore: base", cwd=self.main, check=True)
        run("git", "branch", "-M", "master", cwd=self.main, check=True)
        run("git", "remote", "add", "origin", str(self.origin), cwd=self.main, check=True)
        run("git", "push", "-u", "origin", "master", cwd=self.main, check=True)

        run("git", "branch", "feature/测试已有PR更新流程", cwd=self.main, check=True)
        self.worktree.parent.mkdir(parents=True)
        run(
            "git",
            "worktree",
            "add",
            str(self.worktree),
            "feature/测试已有PR更新流程",
            cwd=self.main,
            check=True,
        )
        run("git", "config", "user.name", "Test User", cwd=self.worktree, check=True)
        run("git", "config", "user.email", "test@example.com", cwd=self.worktree, check=True)
        run("git", "config", "commit.gpgsign", "false", cwd=self.worktree, check=True)

    def tearDown(self) -> None:
        self.tempdir.cleanup()

    def git(self, *args: str, cwd: Path | None = None, check: bool = True) -> str:
        result = run("git", *args, cwd=cwd or self.worktree, check=check)
        return result.stdout.strip()

    def commit_task_change(self, content: str = "task\n") -> str:
        (self.worktree / "task.txt").write_text(content, encoding="utf-8")
        self.git("add", "task.txt")
        self.git("commit", "-m", "feat: task change")
        return self.git("rev-parse", "HEAD")

    def advance_master(self, filename: str = "upstream.txt", content: str = "upstream\n") -> str:
        (self.main / filename).write_text(content, encoding="utf-8")
        self.git("add", filename, cwd=self.main)
        self.git("commit", "-m", "chore: upstream change", cwd=self.main)
        self.git("push", "origin", "master", cwd=self.main)
        return self.git("rev-parse", "HEAD", cwd=self.main)

    def invoke(self, *args: str) -> subprocess.CompletedProcess[str]:
        return run("bash", str(SYNC_SCRIPT), *args, cwd=self.worktree)

    def response(self, result: subprocess.CompletedProcess[str]) -> dict[str, object]:
        self.assertTrue(result.stdout.strip(), result.stderr)
        return json.loads(result.stdout.strip().splitlines()[-1])

    def test_sync_rebases_onto_origin_master_and_is_idempotent(self) -> None:
        original_head = self.commit_task_change()
        upstream_head = self.advance_master()

        first = self.invoke("sync", "--json")

        self.assertEqual(first.returncode, 0, first.stderr)
        self.assertEqual(self.response(first)["status"], "SYNCED")
        rebased_head = self.git("rev-parse", "HEAD")
        self.assertNotEqual(rebased_head, original_head)
        self.assertEqual(
            run(
                "git",
                "merge-base",
                "--is-ancestor",
                upstream_head,
                rebased_head,
                cwd=self.worktree,
            ).returncode,
            0,
        )
        git_dir = Path(self.git("rev-parse", "--absolute-git-dir"))
        recovery = json.loads((git_dir / "agent-sync-recovery.json").read_text(encoding="utf-8"))
        self.assertEqual(recovery["original_head"], original_head)
        self.assertEqual(recovery["upstream_sha"], upstream_head)

        second = self.invoke("sync", "--json")

        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertEqual(self.response(second)["status"], "UP_TO_DATE")
        self.assertEqual(self.git("rev-parse", "HEAD"), rebased_head)

    def test_sync_aborts_conflict_and_reports_decision_evidence(self) -> None:
        (self.worktree / "shared.txt").write_text("task side\n", encoding="utf-8")
        self.git("add", "shared.txt")
        self.git("commit", "-m", "fix: task edits shared line")
        original_head = self.git("rev-parse", "HEAD")
        upstream_head = self.advance_master("shared.txt", "upstream side\n")

        result = self.invoke("sync", "--json")

        self.assertEqual(result.returncode, 3, result.stderr)
        payload = self.response(result)
        self.assertEqual(payload["status"], "REBASE_CONFLICT_ABORTED")
        self.assertEqual(payload["original_head"], original_head)
        self.assertEqual(payload["upstream_sha"], upstream_head)
        self.assertEqual(payload["replaying_commit"], original_head)
        self.assertEqual(payload["conflict_files"], ["shared.txt"])
        self.assertEqual(self.git("rev-parse", "HEAD"), original_head)
        self.assertEqual(self.git("status", "--porcelain"), "")
        self.assertTrue(Path(str(payload["recovery_file"])).exists())

    def test_rollback_restores_original_head_and_removes_recovery_point(self) -> None:
        original_head = self.commit_task_change()
        self.advance_master()
        synced = self.invoke("sync", "--json")
        self.assertEqual(synced.returncode, 0, synced.stderr)
        synced_payload = self.response(synced)
        self.assertNotEqual(self.git("rev-parse", "HEAD"), original_head)

        result = self.invoke("rollback", "--json")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.response(result)["status"], "ROLLED_BACK")
        self.assertEqual(self.git("rev-parse", "HEAD"), original_head)
        self.assertFalse(Path(str(synced_payload["recovery_file"])).exists())
        self.assertNotEqual(
            run(
                "git",
                "show-ref",
                "--verify",
                str(synced_payload["backup_ref"]),
                cwd=self.worktree,
            ).returncode,
            0,
        )

    def test_finalize_rejects_recovery_point_that_has_not_been_pushed(self) -> None:
        self.commit_task_change()
        self.advance_master()
        synced = self.invoke("sync", "--json")
        self.assertEqual(synced.returncode, 0, synced.stderr)
        synced_payload = self.response(synced)
        synced_head = self.git("rev-parse", "HEAD")

        result = self.invoke("finalize", "--json")

        self.assertEqual(result.returncode, 1)
        payload = self.response(result)
        self.assertEqual(payload["status"], "ERROR")
        self.assertIn("尚未推送", str(payload["detail"]))
        self.assertEqual(self.git("rev-parse", "HEAD"), synced_head)
        self.assertTrue(Path(str(synced_payload["recovery_file"])).exists())
        self.assertEqual(
            run(
                "git",
                "show-ref",
                "--verify",
                str(synced_payload["backup_ref"]),
                cwd=self.worktree,
            ).returncode,
            0,
        )

    def test_finalize_rejects_dirty_worktree_and_preserves_recovery(self) -> None:
        self.commit_task_change()
        self.advance_master()
        synced = self.invoke("sync", "--json")
        payload = self.response(synced)
        marker = Path(str(payload["recovery_file"]))
        recovery = json.loads(marker.read_text(encoding="utf-8"))
        head = self.git("rev-parse", "HEAD")
        recovery.update(push_state="pushed", pushed_head=head, verified_head=head)
        marker.write_text(json.dumps(recovery), encoding="utf-8")
        (self.worktree / "dirty.txt").write_text("dirty\n", encoding="utf-8")

        result = self.invoke("finalize", "--json")

        self.assertEqual(result.returncode, 1)
        self.assertIn("不干净", str(self.response(result)["detail"]))
        self.assertTrue(marker.exists())

    def test_finalize_preserves_recovery_when_backup_ref_cannot_be_deleted(self) -> None:
        self.commit_task_change()
        self.advance_master()
        synced = self.invoke("sync", "--json")
        payload = self.response(synced)
        marker = Path(str(payload["recovery_file"]))
        recovery = json.loads(marker.read_text(encoding="utf-8"))
        head = self.git("rev-parse", "HEAD")
        recovery.update(push_state="pushed", pushed_head=head, verified_head=head)
        marker.write_text(json.dumps(recovery), encoding="utf-8")
        common = Path(self.git("rev-parse", "--git-common-dir"))
        if not common.is_absolute():
            common = (self.worktree / common).resolve()
        lock = common / (str(payload["backup_ref"]) + ".lock")
        lock.parent.mkdir(parents=True, exist_ok=True)
        lock.write_text("locked", encoding="utf-8")

        result = self.invoke("finalize", "--json")

        self.assertEqual(result.returncode, 1)
        self.assertIn("backup ref", str(self.response(result)["detail"]))
        self.assertTrue(marker.exists())

    def test_sync_rejects_non_structured_ascii_branch(self) -> None:
        self.git("branch", "-m", "feature/ascii-name")

        result = self.invoke("sync", "--json")

        self.assertEqual(result.returncode, 1)
        payload = self.response(result)
        self.assertEqual(payload["status"], "ERROR")
        self.assertIn("结构化", str(payload["detail"]))

    def test_sync_records_existing_remote_source_sha_and_private_marker_mode(self) -> None:
        original_head = self.commit_task_change()
        self.git("push", "-u", "origin", "HEAD")
        self.advance_master()

        result = self.invoke("sync", "--json")

        self.assertEqual(result.returncode, 0, result.stderr)
        payload = self.response(result)
        self.assertEqual(payload["remote_branch_sha"], original_head)
        marker = Path(str(payload["recovery_file"]))
        self.assertEqual(marker.stat().st_mode & 0o777, 0o600)

    def test_recovery_atomic_write_failure_returns_structured_error(self) -> None:
        original_head = self.commit_task_change()
        self.advance_master()
        git_dir = Path(self.git("rev-parse", "--absolute-git-dir"))
        blocked_temporary = git_dir / "agent-sync-recovery.json.tmp"
        blocked_temporary.mkdir()

        result = self.invoke("sync", "--json")

        self.assertEqual(result.returncode, 1)
        payload = self.response(result)
        self.assertEqual(payload["status"], "ERROR")
        self.assertIn("原子写入", str(payload["detail"]))
        self.assertNotIn("Traceback", result.stderr)
        self.assertEqual(self.git("rev-parse", "HEAD"), original_head)

    def test_repeated_sync_preserves_the_original_transaction_recovery_head(self) -> None:
        original_head = self.commit_task_change()
        self.advance_master("upstream-one.txt", "one\n")
        first = self.invoke("sync", "--json")
        self.assertEqual(first.returncode, 0, first.stderr)

        self.advance_master("upstream-two.txt", "two\n")
        second = self.invoke("sync", "--json")

        self.assertEqual(second.returncode, 0, second.stderr)
        payload = self.response(second)
        marker = Path(str(payload["recovery_file"]))
        recovery = json.loads(marker.read_text(encoding="utf-8"))
        self.assertEqual(recovery["original_head"], original_head)

        rollback = self.invoke("rollback", "--json")

        self.assertEqual(rollback.returncode, 0, rollback.stderr)
        self.assertEqual(self.git("rev-parse", "HEAD"), original_head)


if __name__ == "__main__":
    unittest.main()
