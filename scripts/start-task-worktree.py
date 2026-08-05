#!/usr/bin/env python3
"""Synchronize local master, then create a structured Chinese task worktree."""

import argparse
import hashlib
import os
import re
import subprocess
import sys
import unicodedata
from pathlib import Path


ALLOWED_TYPES = ("feature", "fix", "hotfix", "docs", "chore")
ISSUE_RE = re.compile(r"^(?=.*[A-Za-z])[A-Za-z0-9]+$")
CHINESE_RE = re.compile(r"[\u3400-\u4dbf\u4e00-\u9fff]")
MERGE_MESSAGE = "chore: 同步远程 master 更新"
GIT_OPERATION_MARKERS = (
    "MERGE_HEAD",
    "CHERRY_PICK_HEAD",
    "REVERT_HEAD",
    "rebase-merge",
    "rebase-apply",
)


class WorkflowError(RuntimeError):
    pass


def git(cwd, *args, check=True):
    result = subprocess.run(
        ["git", "-C", str(cwd), *args],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if check and result.returncode != 0:
        detail = (result.stderr or result.stdout).strip()
        raise WorkflowError("git {} 失败：{}".format(" ".join(args), detail))
    return result


def normalize_summary(summary):
    value = unicodedata.normalize("NFC", summary.strip())
    if not 6 <= len(value) <= 15:
        raise WorkflowError("中文简述必须为 6–15 个字符。")
    if not CHINESE_RE.search(value):
        raise WorkflowError("简述必须包含中文，禁止纯英文或纯拼音标题。")
    if any(character.isspace() for character in value):
        raise WorkflowError("简述不允许包含空格。")
    if any(character in value for character in ("_", "-", "/")):
        raise WorkflowError("简述内部不允许包含下划线、连字符或斜杠。")
    return value


def validate_issue(issue):
    if issue is None:
        return None
    if not ISSUE_RE.fullmatch(issue):
        raise WorkflowError("工单号必须是包含字母的字母数字串，不能是纯数字。")
    return issue


def build_branch(task_type, issue, summary):
    if task_type not in ALLOWED_TYPES:
        raise WorkflowError("分支类型必须是：{}。".format(" ".join(ALLOWED_TYPES)))
    issue = validate_issue(issue)
    summary = normalize_summary(summary)
    suffix = "{}-{}".format(issue, summary) if issue else summary
    branch = "{}/{}".format(task_type, suffix)
    result = subprocess.run(
        ["git", "check-ref-format", "--branch", branch],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if result.returncode != 0:
        raise WorkflowError("生成的分支名不符合 Git ref 规则：{}".format(branch))
    return branch


def validate_existing_branch(branch):
    try:
        task_type, suffix = branch.split("/", 1)
    except ValueError as exc:
        raise WorkflowError("分支名必须使用白名单前缀和中文简述。") from exc
    if "-" in suffix:
        issue, summary = suffix.split("-", 1)
    else:
        issue, summary = None, suffix
    expected = build_branch(task_type, issue, summary)
    if expected != branch:
        raise WorkflowError("分支名未使用规范化格式：{}".format(branch))
    return branch


def absolute_git_path(root, value):
    path = Path(value)
    if not path.is_absolute():
        path = root / path
    return path.resolve()


def active_git_operations(root):
    active = []
    for marker in GIT_OPERATION_MARKERS:
        value = git(root, "rev-parse", "--git-path", marker).stdout.strip()
        if absolute_git_path(root, value).exists():
            active.append(marker)
    return active


def ensure_primary_master(root):
    # 路径判等一律 samefile（inode 比较），禁跨来源字面串比较：大小写不敏感
    # 文件系统上 git toplevel（getcwd 规范大小写）与 BASH_SOURCE/pwd 推导的
    # root（逻辑拼写）可能仅大小写不同，字符串比较会把同一目录误判为不同目录。
    # realpath/resolve 保留输入大小写，换用它们不能替代 samefile。
    # 见 docs/adr/0039-path-identity-via-inode-comparison.md
    toplevel = Path(git(root, "rev-parse", "--show-toplevel").stdout.strip())
    if not os.path.samefile(root, toplevel):
        raise WorkflowError("脚本必须从主 checkout 所在仓库执行。")

    git_dir = absolute_git_path(root, git(root, "rev-parse", "--git-dir").stdout.strip())
    common_dir = absolute_git_path(
        root, git(root, "rev-parse", "--git-common-dir").stdout.strip()
    )
    if git_dir != common_dir:
        raise WorkflowError("请在主 checkout 执行，不要在任务 Work Tree 内继续创建。")

    branch = git(root, "branch", "--show-current").stdout.strip()
    if branch != "master":
        raise WorkflowError("主 checkout 当前分支必须是 master，实际为：{}".format(branch or "detached HEAD"))

    operations = active_git_operations(root)
    if operations:
        raise WorkflowError(
            "检测到进行中的 Git 操作：{}。请先完成或显式终止该操作。".format(
                ", ".join(operations)
            )
        )

    status = git(root, "status", "--porcelain").stdout
    if status:
        raise WorkflowError("本地 master 工作区不干净，不能同步或创建 Work Tree。\n{}".format(status.rstrip()))


def is_ancestor(root, ancestor, descendant):
    result = git(
        root, "merge-base", "--is-ancestor", ancestor, descendant, check=False
    )
    if result.returncode not in (0, 1):
        detail = (result.stderr or result.stdout).strip()
        raise WorkflowError("无法比较 master 历史：{}".format(detail))
    return result.returncode == 0


def synchronize_master(root):
    git(root, "fetch", "origin", "master")

    if is_ancestor(root, "origin/master", "master"):
        action = "本地 master 已包含最新远程提交"
    elif is_ancestor(root, "master", "origin/master"):
        git(root, "merge", "--ff-only", "origin/master")
        action = "本地 master 已 fast-forward 到 origin/master"
    else:
        merge = git(
            root,
            "merge",
            "--no-ff",
            "-m",
            MERGE_MESSAGE,
            "origin/master",
            check=False,
        )
        if merge.returncode != 0:
            abort = git(root, "merge", "--abort", check=False)
            detail = (merge.stderr or merge.stdout).strip()
            if abort.returncode == 0:
                message = "本地 master 与 origin/master 合并发生冲突，已自动 abort；未创建 Work Tree。\n{}".format(
                    detail
                )
            else:
                abort_detail = (abort.stderr or abort.stdout).strip()
                message = (
                    "本地 master 与 origin/master 合并发生冲突，自动 abort 未成功；"
                    "请手动执行 git merge --abort 后重试。未创建 Work Tree。\n"
                    "合并输出：{}\nabort 输出：{}".format(detail, abort_detail)
                )
            raise WorkflowError(message)
        action = "本地 master 已合并 origin/master，并保留双方提交"

    if git(root, "status", "--porcelain").stdout:
        raise WorkflowError("同步后的 master 工作区异常变脏，已停止创建 Work Tree。")
    return git(root, "rev-parse", "master").stdout.strip(), action


def derive_target(root, task_type, issue, summary):
    if issue:
        directory = "{}-{}".format(task_type, issue.lower())
    else:
        digest = hashlib.sha256(summary.encode("utf-8")).hexdigest()[:8]
        directory = "{}-{}".format(task_type, digest)
    return root.parent / "blue-whale-worktrees" / directory


def create_worktree(args):
    root = Path(__file__).resolve().parents[1]
    issue = args.issue if not args.no_issue else None
    summary = normalize_summary(args.summary)
    branch = build_branch(args.task_type, issue, summary)
    target = derive_target(root, args.task_type, issue, summary)

    ensure_primary_master(root)
    if git(root, "show-ref", "--verify", "--quiet", "refs/heads/{}".format(branch), check=False).returncode == 0:
        raise WorkflowError("本地分支已存在：{}".format(branch))
    if target.exists():
        raise WorkflowError("目标 Work Tree 已存在：{}".format(target))

    base_sha, action = synchronize_master(root)
    target.parent.mkdir(parents=True, exist_ok=True)
    git(root, "worktree", "add", str(target), "-b", branch, base_sha)

    print("✅ {}".format(action))
    print("✅ 已创建中文任务分支：{}".format(branch))
    print("✅ Work Tree：{}".format(target))
    print("✅ 基准提交：{}".format(base_sha))
    print("下一步：将 Agent 工作目录切换到该 Work Tree；无法切换时在该目录开启新会话。")


def parse_start_args(argv):
    parser = argparse.ArgumentParser(
        description="同步本地 master 与 origin/master，再创建结构化中文任务 Work Tree。"
    )
    parser.add_argument("--type", dest="task_type", choices=ALLOWED_TYPES, required=True)
    issue_group = parser.add_mutually_exclusive_group(required=True)
    issue_group.add_argument("--issue", help="Gitee 工单号，例如 IK094T")
    issue_group.add_argument("--no-issue", action="store_true", help="明确声明本任务没有工单")
    parser.add_argument("--summary", required=True, help="6–15 字中文动宾简述")
    return parser.parse_args(argv)


def main(argv=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    try:
        if len(argv) == 2 and argv[0] == "--validate-branch":
            validate_existing_branch(argv[1])
            return 0
        create_worktree(parse_start_args(argv))
        return 0
    except WorkflowError as exc:
        print("❌ start-task-worktree: {}".format(exc), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
