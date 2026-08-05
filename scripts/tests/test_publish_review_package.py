#!/usr/bin/env python3
"""Black-box tests for explicit create/update publication modes."""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
PUBLISH_SCRIPT = REPO_ROOT / "scripts" / "publish-review-package.sh"
SYNC_SCRIPT = REPO_ROOT / "scripts" / "sync-task-from-origin.sh"
VERIFY_SCRIPT = REPO_ROOT / "scripts" / "verify-pr-update.sh"
BRANCH = "feature/测试已有PR更新流程"


def run(*args: str, cwd: Path, check: bool = False) -> subprocess.CompletedProcess[str]:
    return subprocess.run(list(args), cwd=cwd, text=True, capture_output=True, check=check)


class PublishReviewPackageTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tempdir = tempfile.TemporaryDirectory()
        self.root = Path(self.tempdir.name)
        self.origin = self.root / "origin.git"
        self.main = self.root / "main"
        self.worktree = self.root / "blue-whale-worktrees" / "feature-test"
        run("git", "init", "--bare", str(self.origin), cwd=self.root, check=True)
        run("git", "init", str(self.main), cwd=self.root, check=True)
        self.configure(self.main)
        (self.main / "base.txt").write_text("base\n", encoding="utf-8")
        self.git("add", "base.txt", cwd=self.main)
        self.git("commit", "-m", "chore: base", cwd=self.main)
        self.git("branch", "-M", "master", cwd=self.main)
        self.git("remote", "add", "origin", str(self.origin), cwd=self.main)
        self.git("push", "-u", "origin", "master", cwd=self.main)
        self.git("branch", BRANCH, cwd=self.main)
        self.worktree.parent.mkdir(parents=True)
        self.git("worktree", "add", str(self.worktree), BRANCH, cwd=self.main)
        self.configure(self.worktree)
        self.commit_followup("initial task")

    def tearDown(self) -> None:
        self.tempdir.cleanup()

    def configure(self, repo: Path) -> None:
        run("git", "config", "user.name", "Test User", cwd=repo, check=True)
        run("git", "config", "user.email", "test@example.com", cwd=repo, check=True)
        run("git", "config", "commit.gpgsign", "false", cwd=repo, check=True)
        run("git", "config", "core.hooksPath", "/dev/null", cwd=repo, check=True)

    def git(self, *args: str, cwd: Path | None = None, check: bool = True) -> str:
        result = run("git", *args, cwd=cwd or self.worktree, check=check)
        return result.stdout.strip()

    def commit_followup(self, content: str) -> str:
        (self.worktree / "task.txt").write_text(content + "\n", encoding="utf-8")
        self.git("add", "task.txt")
        self.git("commit", "-m", "fix: review follow-up")
        return self.git("rev-parse", "HEAD")

    def publish_marker(self) -> Path:
        common = Path(self.git("rev-parse", "--git-common-dir"))
        if not common.is_absolute():
            common = (self.worktree / common).resolve()
        return common / "agent-release-review-package-feature%测试已有PR更新流程"

    def invoke(self, *args: str) -> subprocess.CompletedProcess[str]:
        return run("bash", str(PUBLISH_SCRIPT), *args, cwd=self.worktree)

    def pr_snapshot(
        self,
        *,
        iid: object = 65,
        state: str = "opened",
        source_branch: str = BRANCH,
        target_branch: str = "master",
        head_sha: str | None = None,
        conflict: bool = False,
        changed_files: list[str] | None = None,
    ) -> Path:
        if head_sha is None:
            line = self.git("ls-remote", "--heads", "origin", "refs/heads/{}".format(BRANCH))
            head_sha = line.split()[0] if line else ""
        if changed_files is None and head_sha:
            changed = self.git("diff", "--name-only", "origin/master...{}".format(head_sha))
            changed_files = changed.splitlines() if changed else []
        path = self.root / "pr-snapshot-{}.json".format(time.time_ns())
        path.write_text(
            json.dumps(
                {
                    "pull_request_id": iid,
                    "state": state,
                    "source_branch": source_branch,
                    "target_branch": target_branch,
                    "head_sha": head_sha,
                    "conflict": conflict,
                    "changed_files": changed_files or [],
                    "fetched_at": int(time.time()),
                },
                ensure_ascii=False,
            ),
            encoding="utf-8",
        )
        path.chmod(0o600)
        return path

    def invoke_update(
        self, snapshot: Path | None = None, *extra: str, env: dict[str, str] | None = None
    ) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [
                "bash",
                str(PUBLISH_SCRIPT),
                "--user-authorized",
                "--update-pr",
                "65",
                "--pr-snapshot",
                str(snapshot or self.pr_snapshot()),
                *extra,
                "--json",
            ],
            cwd=self.worktree,
            text=True,
            capture_output=True,
            env=env,
        )

    def response(self, result: subprocess.CompletedProcess[str]) -> dict[str, object]:
        self.assertTrue(result.stdout.strip(), result.stderr)
        return json.loads(result.stdout.strip().splitlines()[-1])

    def test_missing_mode_fails_closed(self) -> None:
        result = self.invoke("--user-authorized", "--json")

        self.assertEqual(result.returncode, 2)
        self.assertEqual(self.response(result)["status"], "INVALID_MODE")

    def test_create_and_update_modes_are_mutually_exclusive(self) -> None:
        result = self.invoke("--user-authorized", "--create-pr", "--update-pr", "65", "--json")

        self.assertEqual(result.returncode, 2)
        self.assertEqual(self.response(result)["status"], "INVALID_MODE")

    def test_update_mode_rejects_invalid_pr_iid(self) -> None:
        result = self.invoke("--user-authorized", "--update-pr", "not-a-number", "--json")

        self.assertEqual(result.returncode, 2)
        self.assertEqual(self.response(result)["status"], "INVALID_PR_IID")

    def test_update_mode_requires_gitee_pr_snapshot(self) -> None:
        result = self.invoke("--user-authorized", "--update-pr", "65", "--json")

        self.assertEqual(result.returncode, 2)
        self.assertEqual(self.response(result)["status"], "PR_SNAPSHOT_REQUIRED")

    def test_create_mode_pushes_and_writes_create_marker(self) -> None:
        expected_head = self.git("rev-parse", "HEAD")

        result = self.invoke("--user-authorized", "--create-pr", "--json")

        self.assertEqual(result.returncode, 0, result.stderr)
        payload = self.response(result)
        self.assertEqual(payload["status"], "PUSHED_CREATE_PR")
        self.assertEqual(payload["head"], expected_head)
        self.assertEqual(
            self.git("ls-remote", "--heads", "origin", "refs/heads/{}".format(BRANCH)).split()[0],
            expected_head,
        )
        self.assertTrue(self.publish_marker().exists())

    def test_update_mode_requires_existing_remote_source_branch(self) -> None:
        result = self.invoke_update(self.pr_snapshot(head_sha=""))

        self.assertEqual(result.returncode, 1)
        self.assertEqual(self.response(result)["status"], "REMOTE_SOURCE_MISSING")
        self.assertFalse(self.publish_marker().exists())

    def test_update_mode_pushes_with_lease_without_create_marker(self) -> None:
        self.git("push", "-u", "origin", "HEAD")
        expected_head = self.commit_followup("second follow-up")

        result = self.invoke_update()

        self.assertEqual(result.returncode, 0, result.stderr)
        payload = self.response(result)
        self.assertEqual(payload["status"], "PUSHED_UPDATE_PR")
        self.assertEqual(payload["pull_request_id"], 65)
        self.assertEqual(payload["head"], expected_head)
        self.assertEqual(payload["merge_commit_count"], 0)
        self.assertIn("task.txt", payload["changed_files"])
        self.assertEqual(
            self.git("ls-remote", "--heads", "origin", "refs/heads/{}".format(BRANCH)).split()[0],
            expected_head,
        )
        self.assertFalse(self.publish_marker().exists())

    def test_update_mode_rejects_task_branch_merge_commits(self) -> None:
        remote_head = self.git("rev-parse", "HEAD")
        self.git("push", "-u", "origin", "HEAD")
        self.git("branch", "feature/其他工单")
        self.git("checkout", "feature/其他工单")
        (self.worktree / "unrelated.txt").write_text("unrelated\n", encoding="utf-8")
        self.git("add", "unrelated.txt")
        self.git("commit", "-m", "feat: unrelated task")
        self.git("checkout", BRANCH)
        self.git("merge", "--no-ff", "feature/其他工单", "-m", "chore: merge unrelated task")

        result = self.invoke_update()

        self.assertEqual(result.returncode, 6)
        payload = self.response(result)
        self.assertEqual(payload["status"], "SCOPE_MERGE_COMMIT_DETECTED")
        self.assertGreater(payload["merge_commit_count"], 0)
        self.assertEqual(
            self.git("ls-remote", "--heads", "origin", "refs/heads/{}".format(BRANCH)).split()[0],
            remote_head,
        )

    def test_update_mode_rejects_unknown_remote_change_after_sync_snapshot(self) -> None:
        remote_before = self.git("rev-parse", "HEAD")
        self.git("push", "-u", "origin", "HEAD")
        self.commit_followup("local review fix")
        (self.main / "upstream.txt").write_text("upstream\n", encoding="utf-8")
        self.git("add", "upstream.txt", cwd=self.main)
        self.git("commit", "-m", "chore: advance master", cwd=self.main)
        self.git("push", "origin", "master", cwd=self.main)
        synced = run("bash", str(SYNC_SCRIPT), "sync", "--json", cwd=self.worktree)
        self.assertEqual(synced.returncode, 0, synced.stderr)

        attacker = self.root / "attacker"
        run("git", "clone", str(self.origin), str(attacker), cwd=self.root, check=True)
        self.configure(attacker)
        self.git("checkout", "-b", BRANCH, "origin/{}".format(BRANCH), cwd=attacker)
        (attacker / "remote.txt").write_text("other writer\n", encoding="utf-8")
        self.git("add", "remote.txt", cwd=attacker)
        self.git("commit", "-m", "fix: concurrent remote update", cwd=attacker)
        self.git("push", "origin", BRANCH, cwd=attacker)

        result = self.invoke_update(self.pr_snapshot(head_sha=remote_before))

        self.assertEqual(result.returncode, 5)
        payload = self.response(result)
        self.assertEqual(payload["status"], "REMOTE_LEASE_CHANGED")
        self.assertEqual(payload["expected_remote_sha"], remote_before)
        self.assertNotEqual(payload["actual_remote_sha"], remote_before)

    def test_successful_update_prevents_local_rollback_until_remote_is_adjudicated(self) -> None:
        self.git("push", "-u", "origin", "HEAD")
        self.commit_followup("local review fix")
        (self.main / "upstream.txt").write_text("upstream\n", encoding="utf-8")
        self.git("add", "upstream.txt", cwd=self.main)
        self.git("commit", "-m", "chore: advance master", cwd=self.main)
        self.git("push", "origin", "master", cwd=self.main)
        synced = run("bash", str(SYNC_SCRIPT), "sync", "--json", cwd=self.worktree)
        self.assertEqual(synced.returncode, 0, synced.stderr)
        published = self.invoke_update()
        self.assertEqual(published.returncode, 0, published.stderr)

        rollback = run("bash", str(SYNC_SCRIPT), "rollback", "--json", cwd=self.worktree)

        self.assertEqual(rollback.returncode, 1)
        payload = self.response(rollback)
        self.assertEqual(payload["status"], "ERROR")
        self.assertIn("推送", str(payload["detail"]))

        finalized = run("bash", str(SYNC_SCRIPT), "finalize", "--json", cwd=self.worktree)

        self.assertEqual(finalized.returncode, 1)
        self.assertIn("远端核验", str(self.response(finalized)["detail"]))

        verified = run(
            "bash",
            str(VERIFY_SCRIPT),
            "--update-pr",
            "65",
            "--pr-snapshot",
            str(self.pr_snapshot(head_sha=self.git("rev-parse", "HEAD"))),
            "--json",
            cwd=self.worktree,
        )
        self.assertEqual(verified.returncode, 0, verified.stderr)
        self.assertEqual(self.response(verified)["status"], "PR_UPDATE_VERIFIED")

        finalized = run("bash", str(SYNC_SCRIPT), "finalize", "--json", cwd=self.worktree)

        self.assertEqual(finalized.returncode, 0, finalized.stderr)
        self.assertEqual(self.response(finalized)["status"], "FINALIZED")

    def test_pr_identity_is_verified_before_push(self) -> None:
        remote_head = self.git("rev-parse", "HEAD")
        self.git("push", "-u", "origin", "HEAD")
        self.commit_followup("review fix")
        snapshot = self.pr_snapshot(iid=999, head_sha=remote_head)

        result = self.invoke_update(snapshot)

        self.assertEqual(result.returncode, 8)
        self.assertEqual(self.response(result)["status"], "PR_EVIDENCE_INVALID")
        self.assertEqual(
            self.git("ls-remote", "--heads", "origin", "refs/heads/{}".format(BRANCH)).split()[0],
            remote_head,
        )

    def test_malformed_pr_iid_still_returns_structured_json(self) -> None:
        remote_head = self.git("rev-parse", "HEAD")
        self.git("push", "-u", "origin", "HEAD")
        self.commit_followup("review fix")
        for malformed in (None, [], {}):
            with self.subTest(pull_request_id=malformed):
                result = self.invoke_update(self.pr_snapshot(iid=malformed, head_sha=remote_head))
                self.assertEqual(result.returncode, 8)
                self.assertEqual(self.response(result)["status"], "PR_EVIDENCE_INVALID")

    def test_closed_or_misbound_pr_is_rejected_before_push(self) -> None:
        remote_head = self.git("rev-parse", "HEAD")
        self.git("push", "-u", "origin", "HEAD")
        self.commit_followup("review fix")
        cases = (
            {"state": "closed"},
            {"source_branch": "feature/其他分支"},
            {"target_branch": "develop"},
        )
        for overrides in cases:
            with self.subTest(overrides=overrides):
                snapshot = self.pr_snapshot(head_sha=remote_head, **overrides)
                result = self.invoke_update(snapshot)
                self.assertEqual(result.returncode, 8)
                self.assertEqual(self.response(result)["status"], "PR_EVIDENCE_INVALID")
        self.assertEqual(
            self.git("ls-remote", "--heads", "origin", "refs/heads/{}".format(BRANCH)).split()[0],
            remote_head,
        )

    def test_scope_snapshot_rejects_unapproved_new_file_before_push(self) -> None:
        remote_head = self.git("rev-parse", "HEAD")
        self.git("push", "-u", "origin", "HEAD")
        (self.worktree / "unrelated.txt").write_text("unrelated\n", encoding="utf-8")
        self.git("add", "unrelated.txt")
        self.git("commit", "-m", "feat: unrelated linear change")
        snapshot = self.pr_snapshot(head_sha=remote_head, changed_files=["task.txt"])

        result = self.invoke_update(snapshot)

        self.assertEqual(result.returncode, 8)
        self.assertIn("冻结范围外", str(self.response(result)["detail"]))
        self.assertEqual(
            self.git("ls-remote", "--heads", "origin", "refs/heads/{}".format(BRANCH)).split()[0],
            remote_head,
        )

    def test_remote_read_failure_returns_structured_status(self) -> None:
        real_git = shutil.which("git") or "/usr/bin/git"
        fake_bin = self.root / "fake-git-bin"
        fake_bin.mkdir()
        fake_git = fake_bin / "git"
        fake_git.write_text(
            "#!/bin/sh\n"
            "case \" $* \" in *\" fetch origin master \"*) exit 71 ;; esac\n"
            "exec \"{}\" \"$@\"\n".format(real_git),
            encoding="utf-8",
        )
        fake_git.chmod(0o755)
        env = os.environ.copy()
        env["PATH"] = "{}:{}".format(fake_bin, env["PATH"])

        result = subprocess.run(
            ["bash", str(PUBLISH_SCRIPT), "--user-authorized", "--create-pr", "--json"],
            cwd=self.worktree,
            text=True,
            capture_output=True,
            env=env,
        )

        self.assertEqual(result.returncode, 7)
        self.assertEqual(self.response(result)["status"], "REMOTE_READ_FAILED")

    def test_ls_remote_failure_returns_structured_status(self) -> None:
        real_git = shutil.which("git") or "/usr/bin/git"
        fake_bin = self.root / "fake-ls-remote-bin"
        fake_bin.mkdir()
        fake_git = fake_bin / "git"
        fake_git.write_text(
            "#!/bin/sh\n"
            "case \" $* \" in *\" ls-remote --heads origin \"*) exit 72 ;; esac\n"
            "exec \"{}\" \"$@\"\n".format(real_git),
            encoding="utf-8",
        )
        fake_git.chmod(0o755)
        env = os.environ.copy()
        env["PATH"] = "{}:{}".format(fake_bin, env["PATH"])

        result = subprocess.run(
            ["bash", str(PUBLISH_SCRIPT), "--user-authorized", "--create-pr", "--json"],
            cwd=self.worktree,
            text=True,
            capture_output=True,
            env=env,
        )

        self.assertEqual(result.returncode, 7)
        self.assertEqual(self.response(result)["status"], "REMOTE_READ_FAILED")

    def test_post_push_verification_rejects_conflict_or_diff_mismatch(self) -> None:
        self.git("push", "-u", "origin", "HEAD")
        head = self.git("rev-parse", "HEAD")
        for snapshot in (
            self.pr_snapshot(head_sha=head, conflict=True),
            self.pr_snapshot(head_sha=head, changed_files=[]),
        ):
            with self.subTest(snapshot=snapshot):
                result = run(
                    "bash",
                    str(VERIFY_SCRIPT),
                    "--update-pr",
                    "65",
                    "--pr-snapshot",
                    str(snapshot),
                    "--json",
                    cwd=self.worktree,
                )
                self.assertEqual(result.returncode, 8)
                self.assertEqual(self.response(result)["status"], "PR_EVIDENCE_INVALID")

    def test_push_success_with_marker_write_failure_still_blocks_rollback(self) -> None:
        self.git("push", "-u", "origin", "HEAD")
        self.commit_followup("local review fix")
        (self.main / "upstream.txt").write_text("upstream\n", encoding="utf-8")
        self.git("add", "upstream.txt", cwd=self.main)
        self.git("commit", "-m", "chore: advance master", cwd=self.main)
        self.git("push", "origin", "master", cwd=self.main)
        synced = run("bash", str(SYNC_SCRIPT), "sync", "--json", cwd=self.worktree)
        self.assertEqual(synced.returncode, 0, synced.stderr)
        recovery_file = Path(str(self.response(synced)["recovery_file"]))

        real_git = shutil.which("git") or "/usr/bin/git"
        fake_bin = self.root / "post-push-failure-bin"
        fake_bin.mkdir()
        fake_git = fake_bin / "git"
        fake_git.write_text(
            "#!/bin/sh\n"
            "\"{}\" \"$@\"\n"
            "status=$?\n"
            "case \" $* \" in *\" push \"*) [ $status -ne 0 ] || mkdir \"$FAIL_RECOVERY_TMP\" ;; esac\n"
            "exit $status\n".format(real_git),
            encoding="utf-8",
        )
        fake_git.chmod(0o755)
        env = os.environ.copy()
        env["PATH"] = "{}:{}".format(fake_bin, env["PATH"])
        env["FAIL_RECOVERY_TMP"] = str(recovery_file) + ".tmp"

        published = self.invoke_update(env=env)

        self.assertNotEqual(published.returncode, 0)
        self.assertEqual(
            self.git("ls-remote", "--heads", "origin", "refs/heads/{}".format(BRANCH)).split()[0],
            self.git("rev-parse", "HEAD"),
        )
        rollback = run("bash", str(SYNC_SCRIPT), "rollback", "--json", cwd=self.worktree)
        self.assertEqual(rollback.returncode, 1)
        self.assertIn("推送", str(self.response(rollback)["detail"]))

    def test_lost_push_ack_keeps_fail_closed_state_and_blocks_rollback(self) -> None:
        self.git("push", "-u", "origin", "HEAD")
        self.commit_followup("local review fix")
        (self.main / "upstream.txt").write_text("upstream\n", encoding="utf-8")
        self.git("add", "upstream.txt", cwd=self.main)
        self.git("commit", "-m", "chore: advance master", cwd=self.main)
        self.git("push", "origin", "master", cwd=self.main)
        synced = run("bash", str(SYNC_SCRIPT), "sync", "--json", cwd=self.worktree)
        self.assertEqual(synced.returncode, 0, synced.stderr)

        real_git = shutil.which("git") or "/usr/bin/git"
        fake_bin = self.root / "lost-ack-bin"
        fake_bin.mkdir()
        fake_git = fake_bin / "git"
        fake_git.write_text(
            "#!/bin/sh\n"
            "case \" $* \" in\n"
            "  *\" push \"*) \"{}\" \"$@\" || exit $?; exit 73 ;;\n"
            "esac\n"
            "exec \"{}\" \"$@\"\n".format(real_git, real_git),
            encoding="utf-8",
        )
        fake_git.chmod(0o755)
        env = os.environ.copy()
        env["PATH"] = "{}:{}".format(fake_bin, env["PATH"])

        published = self.invoke_update(env=env)

        self.assertEqual(published.returncode, 5)
        self.assertEqual(
            self.git("ls-remote", "--heads", "origin", "refs/heads/{}".format(BRANCH)).split()[0],
            self.git("rev-parse", "HEAD"),
        )
        rollback = run("bash", str(SYNC_SCRIPT), "rollback", "--json", cwd=self.worktree)
        self.assertEqual(rollback.returncode, 1)
        self.assertIn("推送", str(self.response(rollback)["detail"]))

    def test_successful_create_after_sync_also_prevents_local_rollback(self) -> None:
        (self.main / "upstream.txt").write_text("upstream\n", encoding="utf-8")
        self.git("add", "upstream.txt", cwd=self.main)
        self.git("commit", "-m", "chore: advance master", cwd=self.main)
        self.git("push", "origin", "master", cwd=self.main)
        synced = run("bash", str(SYNC_SCRIPT), "sync", "--json", cwd=self.worktree)
        self.assertEqual(synced.returncode, 0, synced.stderr)
        published = self.invoke("--user-authorized", "--create-pr", "--json")
        self.assertEqual(published.returncode, 0, published.stderr)

        rollback = run("bash", str(SYNC_SCRIPT), "rollback", "--json", cwd=self.worktree)

        self.assertEqual(rollback.returncode, 1)
        payload = self.response(rollback)
        self.assertEqual(payload["status"], "ERROR")
        self.assertIn("推送", str(payload["detail"]))

        verified = run(
            "bash",
            str(VERIFY_SCRIPT),
            "--update-pr",
            "65",
            "--pr-snapshot",
            str(self.pr_snapshot(head_sha=self.git("rev-parse", "HEAD"))),
            "--json",
            cwd=self.worktree,
        )
        self.assertEqual(verified.returncode, 0, verified.stderr)
        finalized = run("bash", str(SYNC_SCRIPT), "finalize", "--json", cwd=self.worktree)
        self.assertEqual(finalized.returncode, 0, finalized.stderr)

    def test_publish_recovery_helpers_skip_windows_store_python_stub(self) -> None:
        (self.main / "upstream.txt").write_text("upstream\n", encoding="utf-8")
        self.git("add", "upstream.txt", cwd=self.main)
        self.git("commit", "-m", "chore: advance master", cwd=self.main)
        self.git("push", "origin", "master", cwd=self.main)
        synced = run("bash", str(SYNC_SCRIPT), "sync", "--json", cwd=self.worktree)
        self.assertEqual(synced.returncode, 0, synced.stderr)

        fake_bin = self.root / "WindowsApps"
        fake_bin.mkdir()
        python_stub = fake_bin / "python3"
        python_stub.write_text("#!/bin/sh\nexit 91\n", encoding="utf-8")
        python_stub.chmod(0o755)
        py_launcher = fake_bin / "py"
        py_launcher.write_text(
            "#!/bin/sh\n[ \"$1\" = \"-3\" ] && shift\nexec \"{}\" \"$@\"\n".format(sys.executable),
            encoding="utf-8",
        )
        py_launcher.chmod(0o755)
        env = os.environ.copy()
        env["PATH"] = "{}:{}".format(fake_bin, env["PATH"])

        result = subprocess.run(
            ["bash", str(PUBLISH_SCRIPT), "--user-authorized", "--create-pr", "--json"],
            cwd=self.worktree,
            text=True,
            capture_output=True,
            env=env,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.response(result)["status"], "PUSHED_CREATE_PR")


if __name__ == "__main__":
    unittest.main()
