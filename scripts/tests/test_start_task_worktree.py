#!/usr/bin/env python3
"""Black-box tests for the cross-platform task worktree entrypoint."""

import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


SOURCE = Path(__file__).resolve().parents[1] / "start-task-worktree.py"
SOURCE_SH = Path(__file__).resolve().parents[1] / "start-task-worktree.sh"
SOURCE_LIB = Path(__file__).resolve().parents[1] / "lib" / "python3-command.sh"
SOURCE_PRE_PUSH = Path(__file__).resolve().parents[2] / ".githooks/pre-push"


def run(*args, cwd, check=True):
    result = subprocess.run(
        [str(arg) for arg in args],
        cwd=str(cwd),
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if check and result.returncode != 0:
        raise AssertionError(
            "command failed: {}\nstdout:\n{}\nstderr:\n{}".format(
                " ".join(str(arg) for arg in args), result.stdout, result.stderr
            )
        )
    return result


class StartTaskWorktreeTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.repo = self.root / "project"
        self.origin = self.root / "origin.git"
        self.actor = self.root / "actor"

        self.assertTrue(SOURCE.exists(), "production entrypoint does not exist yet")
        self.assertTrue(SOURCE_SH.exists(), "shell compatibility wrapper does not exist")
        self.assertTrue(SOURCE_LIB.exists(), "shared python3 launcher lib does not exist")
        self.assertTrue(SOURCE_PRE_PUSH.exists(), "pre-push hook does not exist")
        run("git", "init", "--bare", "--initial-branch=master", self.origin, cwd=self.root)
        run("git", "init", "--initial-branch=master", self.repo, cwd=self.root)
        self.configure_user(self.repo)

        scripts = self.repo / "scripts"
        scripts.mkdir()
        shutil.copy2(SOURCE, scripts / SOURCE.name)
        shutil.copy2(SOURCE_SH, scripts / SOURCE_SH.name)
        lib = scripts / "lib"
        lib.mkdir()
        shutil.copy2(SOURCE_LIB, lib / SOURCE_LIB.name)
        hooks = self.repo / ".githooks"
        hooks.mkdir()
        shutil.copy2(SOURCE_PRE_PUSH, hooks / "pre-push")
        (self.repo / "shared.txt").write_text("base\n", encoding="utf-8")
        run("git", "add", ".", cwd=self.repo)
        run("git", "commit", "-m", "chore: 初始化测试仓库", cwd=self.repo)
        run("git", "remote", "add", "origin", self.origin, cwd=self.repo)
        run("git", "push", "-u", "origin", "master", cwd=self.repo)

        run("git", "clone", self.origin, self.actor, cwd=self.root)
        self.configure_user(self.actor)

    def tearDown(self):
        self.temp.cleanup()

    @staticmethod
    def configure_user(repo):
        run("git", "config", "user.name", "Worktree Test", cwd=repo)
        run("git", "config", "user.email", "worktree-test@example.com", cwd=repo)

    @staticmethod
    def commit(repo, filename, content, message):
        (repo / filename).write_text(content, encoding="utf-8")
        run("git", "add", filename, cwd=repo)
        run("git", "commit", "-m", message, cwd=repo)
        return run("git", "rev-parse", "HEAD", cwd=repo).stdout.strip()

    def invoke(self, *args):
        return run(sys.executable, self.repo / "scripts/start-task-worktree.py", *args, cwd=self.repo, check=False)

    def pre_push(self, branch, sha=None, remote_sha=None):
        sha = sha or run("git", "rev-parse", "HEAD", cwd=self.repo).stdout.strip()
        remote_sha = remote_sha or "0" * 40
        return subprocess.run(
            ["bash", str(self.repo / ".githooks/pre-push")],
            cwd=str(self.repo),
            input="refs/heads/{0} {1} refs/heads/{0} {2}\n".format(
                branch, sha, remote_sha
            ),
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )

    def task_worktree(self):
        output = run("git", "worktree", "list", "--porcelain", cwd=self.repo).stdout
        paths = [
            Path(line.removeprefix("worktree "))
            for line in output.splitlines()
            if line.startswith("worktree ")
        ]
        tasks = [path for path in paths if path.resolve() != self.repo.resolve()]
        self.assertEqual(1, len(tasks), output)
        return tasks[0]

    def assert_worktree_matches_master(self):
        task = self.task_worktree()
        master_sha = run("git", "rev-parse", "master", cwd=self.repo).stdout.strip()
        task_sha = run("git", "rev-parse", "HEAD", cwd=task).stdout.strip()
        self.assertEqual(master_sha, task_sha)
        return task

    def test_generates_structured_chinese_branch(self):
        result = self.invoke(
            "--type", "fix", "--issue", "IK094T", "--summary", "修复工作树写入护栏"
        )
        self.assertEqual(0, result.returncode, result.stderr)
        task = self.assert_worktree_matches_master()
        branch = run("git", "branch", "--show-current", cwd=task).stdout.strip()
        self.assertEqual("fix/IK094T-修复工作树写入护栏", branch)

    def test_shell_wrapper_only_forwards_structured_arguments(self):
        result = run(
            "bash",
            self.repo / "scripts/start-task-worktree.sh",
            "--type",
            "docs",
            "--no-issue",
            "--summary",
            "补全工作树使用说明",
            cwd=self.repo,
            check=False,
        )
        self.assertEqual(0, result.returncode, result.stderr)
        task = self.assert_worktree_matches_master()
        branch = run("git", "branch", "--show-current", cwd=task).stdout.strip()
        self.assertEqual("docs/补全工作树使用说明", branch)

    def test_branch_validation_mode_supports_hooks(self):
        valid = self.invoke("--validate-branch", "chore/实施极简工作树流程")
        self.assertEqual(0, valid.returncode, valid.stderr)
        invalid_branches = (
            "bug/修复工作树写入护栏",
            "chore/implement-worktree",
            "chore/中文短",
            "chore/完善_工作树启动流程",
            "chore/完善 工作树启动流程",
            "chore/完善-工作树启动流程",
            "fix/123-修复工作树写入护栏",
        )
        for branch in invalid_branches:
            with self.subTest(branch=branch):
                invalid = self.invoke("--validate-branch", branch)
                self.assertNotEqual(0, invalid.returncode, branch)

    def test_pre_push_blocks_invalid_name_and_allows_valid_chinese_name(self):
        valid = self.pre_push("chore/实施极简工作树流程")
        invalid = self.pre_push("chore/implement-worktree")
        self.assertEqual(0, valid.returncode, valid.stderr)
        self.assertNotEqual(0, invalid.returncode)
        self.assertIn("结构化中文规范", invalid.stderr)

    def test_pre_push_without_upstream_only_skips_staleness_check(self):
        run("git", "remote", "remove", "origin", cwd=self.repo)
        valid = self.pre_push("chore/实施极简工作树流程")
        invalid = self.pre_push("chore/implement-worktree")
        protected = self.pre_push("master")
        self.assertEqual(0, valid.returncode, valid.stderr)
        self.assertNotEqual(0, invalid.returncode)
        self.assertIn("结构化中文规范", invalid.stderr)
        self.assertNotEqual(0, protected.returncode)
        self.assertIn("禁止直推", protected.stderr)

    def test_pre_push_blocks_deleting_protected_branch(self):
        zero = "0" * 40
        remote_sha = run("git", "rev-parse", "origin/master", cwd=self.repo).stdout.strip()
        deletion = self.pre_push("master", sha=zero, remote_sha=remote_sha)
        self.assertNotEqual(0, deletion.returncode)
        self.assertIn("禁止直推", deletion.stderr)

    def test_pre_push_allows_already_published_legacy_ascii_branch(self):
        run("git", "checkout", "-b", "chore/legacy-ascii", cwd=self.actor)
        run("git", "push", "-u", "origin", "chore/legacy-ascii", cwd=self.actor)
        legacy_sha = run("git", "rev-parse", "HEAD", cwd=self.actor).stdout.strip()
        legacy = self.pre_push(
            "chore/legacy-ascii", legacy_sha, remote_sha=legacy_sha
        )
        self.assertEqual(0, legacy.returncode, legacy.stderr)

    def test_pre_push_does_not_trust_stale_remote_tracking_ref(self):
        sha = run("git", "rev-parse", "HEAD", cwd=self.repo).stdout.strip()
        run(
            "git",
            "update-ref",
            "refs/remotes/origin/chore/new-ascii",
            sha,
            cwd=self.repo,
        )
        new_branch = self.pre_push("chore/new-ascii", sha)
        self.assertNotEqual(0, new_branch.returncode)
        self.assertIn("结构化中文规范", new_branch.stderr)

    def test_rejects_ascii_summary_without_creating_worktree(self):
        before = run("git", "rev-parse", "master", cwd=self.repo).stdout.strip()
        result = self.invoke(
            "--type", "fix", "--no-issue", "--summary", "fixworktree"
        )
        self.assertNotEqual(0, result.returncode)
        self.assertIn("中文", result.stderr)
        self.assertEqual(before, run("git", "rev-parse", "master", cwd=self.repo).stdout.strip())
        self.assertFalse((self.root / "blue-whale-worktrees").exists())

    def test_rejects_dirty_master(self):
        (self.repo / "dirty.txt").write_text("dirty\n", encoding="utf-8")
        result = self.invoke(
            "--type", "chore", "--no-issue", "--summary", "完善工作树启动流程"
        )
        self.assertNotEqual(0, result.returncode)
        self.assertIn("不干净", result.stderr)
        self.assertFalse((self.root / "blue-whale-worktrees").exists())

    def test_rejects_in_progress_merge_without_aborting_it(self):
        self.commit(self.repo, "shared.txt", "same\n", "fix: 修改本地共享内容")
        self.commit(self.actor, "shared.txt", "same\n", "fix: 修改远程共享内容")
        run("git", "push", "origin", "master", cwd=self.actor)
        run("git", "fetch", "origin", "master", cwd=self.repo)
        run("git", "merge", "--no-commit", "--no-ff", "origin/master", cwd=self.repo)
        self.assertEqual("", run("git", "status", "--porcelain", cwd=self.repo).stdout)
        merge_head = run("git", "rev-parse", "--verify", "MERGE_HEAD", cwd=self.repo).stdout.strip()

        result = self.invoke(
            "--type", "fix", "--no-issue", "--summary", "保护进行中合并状态"
        )

        self.assertNotEqual(0, result.returncode)
        self.assertIn("进行中的 Git 操作", result.stderr)
        self.assertEqual(
            merge_head,
            run("git", "rev-parse", "--verify", "MERGE_HEAD", cwd=self.repo).stdout.strip(),
        )
        self.assertFalse((self.root / "blue-whale-worktrees").exists())

    def test_local_ahead_is_preserved_as_worktree_base(self):
        local_sha = self.commit(
            self.repo, "local.txt", "local\n", "feat: 添加本地模块改动"
        )
        result = self.invoke(
            "--type", "feature", "--no-issue", "--summary", "保留本地模块更新"
        )
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual(local_sha, run("git", "rev-parse", "master", cwd=self.repo).stdout.strip())
        self.assert_worktree_matches_master()

    def test_remote_ahead_fast_forwards_master_before_creation(self):
        remote_sha = self.commit(
            self.actor, "remote.txt", "remote\n", "feat: 添加远程模块改动"
        )
        run("git", "push", "origin", "master", cwd=self.actor)
        result = self.invoke(
            "--type", "feature", "--no-issue", "--summary", "融合远程模块更新"
        )
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual(remote_sha, run("git", "rev-parse", "master", cwd=self.repo).stdout.strip())
        self.assert_worktree_matches_master()

    def test_diverged_master_merges_both_histories_before_creation(self):
        local_sha = self.commit(
            self.repo, "local.txt", "local\n", "feat: 添加本地模块改动"
        )
        remote_sha = self.commit(
            self.actor, "remote.txt", "remote\n", "feat: 添加远程模块改动"
        )
        run("git", "push", "origin", "master", cwd=self.actor)

        result = self.invoke(
            "--type", "feature", "--no-issue", "--summary", "融合本地远程更新"
        )
        self.assertEqual(0, result.returncode, result.stderr)
        run("git", "merge-base", "--is-ancestor", local_sha, "master", cwd=self.repo)
        run("git", "merge-base", "--is-ancestor", remote_sha, "master", cwd=self.repo)
        parents = run("git", "rev-list", "--parents", "-n", "1", "master", cwd=self.repo).stdout.split()
        self.assertEqual(3, len(parents), parents)
        self.assert_worktree_matches_master()

    def test_conflict_aborts_and_does_not_create_worktree(self):
        local_sha = self.commit(
            self.repo, "shared.txt", "local\n", "fix: 修改本地共享内容"
        )
        self.commit(self.actor, "shared.txt", "remote\n", "fix: 修改远程共享内容")
        run("git", "push", "origin", "master", cwd=self.actor)

        result = self.invoke(
            "--type", "fix", "--no-issue", "--summary", "处理共享内容冲突"
        )
        self.assertNotEqual(0, result.returncode)
        self.assertIn("冲突", result.stderr)
        self.assertEqual(local_sha, run("git", "rev-parse", "master", cwd=self.repo).stdout.strip())
        self.assertEqual("", run("git", "status", "--porcelain", cwd=self.repo).stdout)
        self.assertFalse((self.root / "blue-whale-worktrees").exists())

    def test_conflict_abort_failure_reports_honestly_without_claiming_success(self):
        # 与上一用例同样的分叉冲突，但通过 PATH 注入假 git，让 merge --abort
        # 强制失败，其余 git 调用透传真实 git，验证文案如实、不误报成功。
        self.commit(self.repo, "shared.txt", "local\n", "fix: 修改本地共享内容")
        self.commit(self.actor, "shared.txt", "remote\n", "fix: 修改远程共享内容")
        run("git", "push", "origin", "master", cwd=self.actor)

        fake_dir = self.root / "fake-git-bin"
        fake_dir.mkdir()
        real_git = shutil.which("git")
        fake_git = fake_dir / "git"
        fake_git.write_text(
            "#!/usr/bin/env bash\n"
            "prev=\n"
            'for arg in "$@"; do\n'
            '  if [ "$prev" = "merge" ] && [ "$arg" = "--abort" ]; then\n'
            '    echo "fatal: simulated abort failure (index lock)" >&2\n'
            "    exit 1\n"
            "  fi\n"
            '  prev="$arg"\n'
            "done\n"
            'exec "{real}" "$@"\n'.format(real=real_git),
            encoding="utf-8",
        )
        fake_git.chmod(0o755)

        env = dict(os.environ)
        env["PATH"] = "{fake}{sep}{path}".format(
            fake=fake_dir, sep=os.pathsep, path=env["PATH"]
        )

        result = subprocess.run(
            [
                sys.executable,
                str(self.repo / "scripts/start-task-worktree.py"),
                "--type", "fix", "--no-issue", "--summary", "处理共享内容冲突",
            ],
            cwd=str(self.repo),
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )

        self.assertNotEqual(0, result.returncode, result.stderr)
        self.assertIn("冲突", result.stderr)
        self.assertNotIn("已自动 abort", result.stderr)
        self.assertIn("手动", result.stderr)
        self.assertFalse((self.root / "blue-whale-worktrees").exists())

    def test_wrapper_skips_microsoft_store_python3_stub(self):
        """合成 Store 桩（路径含 WindowsApps）且不提供 py launcher，验证 wrapper 跳过桩、报桩引导、不建 worktree。当前平台 PATH 注入模拟 Windows Git Bash 链路，非真 Windows 冒烟（真 Windows 见 docs/agents/worktree-workflow.md 手动验证）。"""
        store_dir = self.root / "Microsoft" / "WindowsApps"
        store_dir.mkdir(parents=True)
        stub = store_dir / "python3"
        stub.write_text(
            "#!/usr/bin/env bash\n"
            'echo "Python was not found; run from Microsoft Store" >&2\n'
            "exit 9\n",
            encoding="utf-8",
        )
        stub.chmod(0o755)

        env = dict(os.environ)
        env["PATH"] = "{}{}{}".format(store_dir, os.pathsep, env["PATH"])

        result = subprocess.run(
            ["bash", str(self.repo / "scripts/start-task-worktree.sh"),
             "--type", "fix", "--no-issue", "--summary", "跳过桩检测场景"],
            cwd=str(self.repo),
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )

        self.assertNotEqual(0, result.returncode, result.stderr)
        self.assertIn("桩", result.stderr)
        # 桩未被 exec：stderr 不应含桩的特征输出
        self.assertNotIn("Python was not found", result.stderr)
        self.assertFalse((self.root / "blue-whale-worktrees").exists())

    def test_wrapper_falls_back_to_py_launcher_when_python3_is_stub(self):
        """合成桩 + 假 py launcher（shift 去掉 -3，转给真 python3 绝对路径），验证 wrapper 跳过桩后 fallback py -3 成功建 worktree。逻辑等价模拟，非真 Windows 冒烟（真 Windows 见 docs/agents/worktree-workflow.md 手动验证）。"""
        real_python3 = shutil.which("python3")
        self.assertIsNotNone(real_python3, "测试机需有真 python3")

        store_dir = self.root / "Microsoft" / "WindowsApps"
        store_dir.mkdir(parents=True)
        stub = store_dir / "python3"
        stub.write_text(
            "#!/usr/bin/env bash\n"
            'echo "Python was not found; run from Microsoft Store" >&2\n'
            "exit 9\n",
            encoding="utf-8",
        )
        stub.chmod(0o755)

        py_dir = self.root / "py-bin"
        py_dir.mkdir()
        fake_py = py_dir / "py"
        fake_py.write_text(
            "#!/usr/bin/env bash\n"
            "shift\n"
            'exec "{real}" "$@"\n'.format(real=real_python3),
            encoding="utf-8",
        )
        fake_py.chmod(0o755)

        env = dict(os.environ)
        env["PATH"] = "{}{}{}{}{}".format(
            store_dir, os.pathsep, py_dir, os.pathsep, env["PATH"]
        )

        result = subprocess.run(
            ["bash", str(self.repo / "scripts/start-task-worktree.sh"),
             "--type", "fix", "--no-issue", "--summary", "回退py启动器场景"],
            cwd=str(self.repo),
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )

        self.assertEqual(0, result.returncode, result.stderr)
        self.assertNotIn("Python was not found", result.stderr)
        task = self.assert_worktree_matches_master()
        branch = run("git", "branch", "--show-current", cwd=task).stdout.strip()
        self.assertEqual("fix/回退py启动器场景", branch)


if __name__ == "__main__":
    unittest.main()
