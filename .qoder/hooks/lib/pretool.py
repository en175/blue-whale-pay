#!/usr/bin/env python3
"""Helpers for Claude Code PreToolUse hooks.

The shell hooks stay as small bash entrypoints, but security-sensitive parsing
belongs here: JSON strings can contain escaped quotes, and git commands can use
global options before the subcommand, e.g. `git -C ../wt push`.
"""

from __future__ import annotations

import json
import os
import posixpath
import re
import shlex
import subprocess
import sys
from dataclasses import dataclass
from typing import Any


SEPARATORS = {";", "&", "&&", "|", "||", "(", ")"}
WORK_BRANCH_PREFIXES = ("feature/", "fix/", "hotfix/", "docs/", "chore/")
NON_ALIAS_SUBCOMMANDS = {
    "add",
    "branch",
    "checkout",
    "clean",
    "commit",
    "config",
    "diff",
    "fetch",
    "log",
    "merge",
    "pull",
    "push",
    "rebase",
    "reset",
    "restore",
    "rev-parse",
    "show",
    "status",
    "switch",
    "symbolic-ref",
    "worktree",
}
UNSAFE_ALIAS_SUBCOMMANDS = {"unsafe-alias", "alias-cycle"}
# 顶层 key 白名单：命中则读 data 顶层元数据，其余 key 只读 tool_input。
# 最小权限——避免让任意 key 误读顶层元数据。tool_name 仍保留 tool_input 回退以兼容旧测试夹具。
TOP_LEVEL_KEYS = {"tool_name", "hook_event_name", "tool_use_id"}
GIT_GLOBAL_OPTS_WITH_ARG = {
    "-C",
    "-c",
    "--git-dir",
    "--work-tree",
    "--namespace",
    "--exec-path",
    "--config-env",
}
PUSH_OPTS_WITH_ARG = {
    "--receive-pack",
    "--exec",
    "--repo",
    "--push-option",
    "--signed",
}


@dataclass
class GitInvocation:
    subcommand: str
    args: list[str]
    cwd: str | None


@dataclass
class CommandInvocation:
    executable: str
    args: list[str]


def load_pretool() -> dict[str, Any]:
    try:
        data = json.load(sys.stdin)
    except Exception:
        return {}
    return data if isinstance(data, dict) else {}


def value(key: str) -> int:
    data = load_pretool()
    tool_input = data.get("tool_input")
    if not isinstance(tool_input, dict):
        tool_input = data
    if key in TOP_LEVEL_KEYS:
        # tool_name 保留 tool_input 回退以兼容旧测试夹具。
        if key == "tool_name":
            result = data.get("tool_name", tool_input.get("tool_name"))
        elif key == "tool_use_id":
            # Kimi CLI 载荷的关联 id 字段是 tool_call_id（无 tool_use_id）；
            # Claude Code / Codex / ZCode 均带 tool_use_id，优先取之。
            result = data.get("tool_use_id") or data.get("tool_call_id")
        else:
            result = data.get(key)
    elif key == "file_path":
        # Kimi CLI 的 Write/Edit 参数名是 path（无 file_path）。
        result = tool_input.get("file_path") or tool_input.get("path")
    else:
        result = tool_input.get(key)
    if result is None:
        return 1
    if isinstance(result, bool):
        print("true" if result else "false")
    else:
        print(result)
    return 0


def normalize_codex_apply_patch() -> int:
    data = load_pretool()
    tool_input = data.get("tool_input")
    cwd = data.get("cwd")
    if (
        data.get("tool_name") != "apply_patch"
        or not isinstance(tool_input, dict)
        or not isinstance(tool_input.get("command"), str)
        or not isinstance(cwd, str)
        or not cwd
    ):
        return 2

    targets: list[str] = []
    for line in tool_input["command"].splitlines():
        match = re.fullmatch(r"\*\*\* (?:(?:Add|Update|Delete) File|Move to): (.+)", line)
        if match is None:
            if line.startswith("*** ") and line not in {
                "*** Begin Patch",
                "*** End Patch",
                "*** End of File",
            }:
                return 2
            continue
        target = match.group(1)
        if not target:
            return 2
        targets.append(os.path.abspath(os.path.join(cwd, target)))

    if not targets:
        return 2

    correlation = {
        key: data[key] for key in ("session_id", "tool_use_id") if key in data
    }
    for target in targets:
        print(
            json.dumps(
                {
                    "tool_name": "Write",
                    **correlation,
                    "tool_input": {"file_path": target},
                },
                ensure_ascii=False,
            )
        )
    return 0


def shell_tokens(command: str) -> list[str]:
    lexer = shlex.shlex(command, posix=True, punctuation_chars=True)
    lexer.whitespace_split = True
    return list(lexer)


def is_separator(token: str) -> bool:
    return token in SEPARATORS


def is_git_token(token: str) -> bool:
    return posixpath.basename(token) == "git"


def is_assignment(token: str) -> bool:
    if "=" not in token:
        return False
    name, _ = token.split("=", 1)
    return bool(name) and re.match(r"^[A-Za-z_][A-Za-z0-9_]*$", name) is not None


def skip_option_with_optional_inline_arg(tokens: list[str], index: int, opts_with_arg: set[str]) -> int:
    token = tokens[index]
    if token in opts_with_arg:
        return index + 2
    for opt in opts_with_arg:
        if token.startswith(f"{opt}="):
            return index + 1
    if token.startswith("-C") and token != "-C":
        return index + 1
    if token.startswith("-c") and token != "-c":
        return index + 1
    return index + 1


def split_shell_segments(tokens: list[str]) -> list[list[str]]:
    segments: list[list[str]] = []
    current: list[str] = []
    for token in tokens:
        if is_separator(token):
            if current:
                segments.append(current)
                current = []
            continue
        current.append(token)
    if current:
        segments.append(current)
    return segments


def parse_command_segment(segment: list[str]) -> CommandInvocation | None:
    index = 0
    while index < len(segment) and is_assignment(segment[index]):
        index += 1
    if index >= len(segment):
        return None

    if posixpath.basename(segment[index]) == "env":
        index += 1
        while index < len(segment):
            token = segment[index]
            if is_assignment(token):
                index += 1
                continue
            if token in {"-i", "-0"}:
                index += 1
                continue
            if token in {"-u", "-C", "-S"}:
                index += 2
                continue
            if token.startswith("-"):
                index += 1
                continue
            break
        if index >= len(segment):
            return None

    return CommandInvocation(executable=segment[index], args=segment[index + 1 :])


def shell_c_argument(invocation: CommandInvocation) -> str | None:
    if posixpath.basename(invocation.executable) not in {"bash", "sh", "zsh"}:
        return None
    args = invocation.args
    index = 0
    while index < len(args):
        arg = args[index]
        if arg == "-c":
            return args[index + 1] if index + 1 < len(args) else None
        if arg.startswith("-") and "c" in arg[1:]:
            return args[index + 1] if index + 1 < len(args) else None
        if not arg.startswith("-"):
            return None
        index += 1
    return None


def shell_script_invocation(invocation: CommandInvocation) -> CommandInvocation | None:
    if posixpath.basename(invocation.executable) not in {"bash", "sh", "zsh"}:
        return None
    args = invocation.args
    index = 0
    while index < len(args):
        arg = args[index]
        if arg == "-c" or (arg.startswith("-") and "c" in arg[1:]):
            return None
        if arg == "--":
            index += 1
            break
        if not arg.startswith("-"):
            break
        if arg in {"-O", "+O"}:
            index += 2
        else:
            index += 1
    if index >= len(args):
        return None
    return CommandInvocation(executable=args[index], args=args[index + 1 :])


def command_invocations(command: str) -> list[CommandInvocation]:
    try:
        tokens = shell_tokens(command)
    except ValueError:
        return []

    invocations: list[CommandInvocation] = []
    for segment in split_shell_segments(tokens):
        invocation = parse_command_segment(segment)
        if invocation is None:
            continue
        invocations.append(invocation)
        nested = shell_c_argument(invocation)
        if nested:
            invocations.extend(command_invocations(nested))
        script_invocation = shell_script_invocation(invocation)
        if script_invocation:
            invocations.append(script_invocation)
    return invocations


def invokes_command(command: str, executable_name: str, required_arg: str | None = None) -> bool:
    for invocation in command_invocations(command):
        if posixpath.basename(invocation.executable) != executable_name:
            continue
        if required_arg is None or required_arg in invocation.args:
            return True
    return False


def nested_shell_commands(command: str) -> list[str]:
    try:
        tokens = shell_tokens(command)
    except ValueError:
        return []

    result: list[str] = []
    for segment in split_shell_segments(tokens):
        invocation = parse_command_segment(segment)
        if invocation is None:
            continue
        nested = shell_c_argument(invocation)
        if nested:
            result.append(nested)
            result.extend(nested_shell_commands(nested))
    return result


def git_invocations(command: str) -> list[GitInvocation]:
    try:
        tokens = shell_tokens(command)
    except ValueError:
        # Fail closed for release-sensitive checks: a malformed shell string that
        # still mentions git push should be treated as a push by callers.
        if re.search(r"\bgit\b", command) and re.search(r"\bpush\b", command):
            return [GitInvocation(subcommand="push", args=[], cwd=None)]
        return []

    invocations: list[GitInvocation] = []
    index = 0
    while index < len(tokens):
        if not is_git_token(tokens[index]):
            index += 1
            continue

        index += 1
        cwd: str | None = None

        while index < len(tokens) and not is_separator(tokens[index]):
            token = tokens[index]
            if token == "--":
                index += 1
                break
            if token == "-C":
                if index + 1 < len(tokens):
                    cwd = tokens[index + 1]
                index += 2
                continue
            if token.startswith("-C") and token != "-C":
                cwd = token[2:]
                index += 1
                continue
            if token in GIT_GLOBAL_OPTS_WITH_ARG or any(
                token.startswith(f"{opt}=") for opt in GIT_GLOBAL_OPTS_WITH_ARG
            ):
                index = skip_option_with_optional_inline_arg(tokens, index, GIT_GLOBAL_OPTS_WITH_ARG)
                continue
            if token.startswith("-"):
                index += 1
                continue

            subcommand = token
            index += 1
            args: list[str] = []
            while index < len(tokens) and not is_separator(tokens[index]):
                args.append(tokens[index])
                index += 1
            invocation = GitInvocation(subcommand=subcommand, args=args, cwd=cwd)
            invocations.extend(resolve_git_alias(invocation))
            break

        while index < len(tokens) and not is_git_token(tokens[index]):
            if is_separator(tokens[index]):
                index += 1
                break
            index += 1

    for nested in nested_shell_commands(command):
        invocations.extend(git_invocations(nested))

    return invocations


def configured_git_alias(name: str, cwd: str | None) -> str | None:
    if name in NON_ALIAS_SUBCOMMANDS:
        return None
    command = ["git"]
    if cwd:
        command.extend(["-C", cwd])
    command.extend(["config", "--get", f"alias.{name}"])
    try:
        result = subprocess.run(command, capture_output=True, text=True, check=False)
    except OSError:
        return None
    if result.returncode != 0:
        return None
    value = result.stdout.rstrip("\n")
    return value or None


def resolve_git_alias(invocation: GitInvocation, seen: tuple[str, ...] = ()) -> list[GitInvocation]:
    if invocation.subcommand in seen or len(seen) >= 10:
        return [GitInvocation(subcommand="alias-cycle", args=invocation.args, cwd=invocation.cwd)]
    alias = configured_git_alias(invocation.subcommand, invocation.cwd)
    if alias is None:
        return [invocation]
    if alias.startswith("!"):
        return [GitInvocation(subcommand="unsafe-alias", args=invocation.args, cwd=invocation.cwd)]
    try:
        tokens = shlex.split(alias)
    except ValueError:
        return [GitInvocation(subcommand="unsafe-alias", args=invocation.args, cwd=invocation.cwd)]
    if not tokens:
        return [GitInvocation(subcommand="unsafe-alias", args=invocation.args, cwd=invocation.cwd)]
    # Git aliases may expand to global options before the real subcommand, for
    # example ``-c foo.bar=baz push``.  Treat that shape as unsafe instead of
    # mistaking the option for a harmless subcommand; this hook is a safety
    # boundary, so an alias whose effective command is not direct is fail-closed.
    if tokens[0].startswith("-"):
        return [GitInvocation(subcommand="unsafe-alias", args=invocation.args, cwd=invocation.cwd)]
    expanded = GitInvocation(
        subcommand=tokens[0],
        args=tokens[1:] + invocation.args,
        cwd=invocation.cwd,
    )
    return resolve_git_alias(expanded, seen + (invocation.subcommand,))


def has_inline_alias_override(command: str) -> bool:
    try:
        tokens = shell_tokens(command)
    except ValueError:
        return bool(re.search(r"\balias\.[A-Za-z0-9_-]+\s*=", command))
    for index, token in enumerate(tokens):
        if token == "-c" and index + 1 < len(tokens) and tokens[index + 1].startswith("alias."):
            return True
        if token.startswith("-calias.") or token.startswith("--config-env=alias."):
            return True
        if token == "--config-env" and index + 1 < len(tokens) and tokens[index + 1].startswith("alias."):
            return True
    return any(has_inline_alias_override(nested) for nested in nested_shell_commands(command))


def push_invocations(command: str) -> list[GitInvocation]:
    return [inv for inv in git_invocations(command) if inv.subcommand == "push"]


def push_positionals(args: list[str]) -> list[str]:
    result: list[str] = []
    index = 0
    passthrough = False
    while index < len(args):
        arg = args[index]
        if not passthrough and arg == "--":
            passthrough = True
            index += 1
            continue
        if not passthrough and arg.startswith("-"):
            if arg in PUSH_OPTS_WITH_ARG or any(arg.startswith(f"{opt}=") for opt in PUSH_OPTS_WITH_ARG):
                index = skip_option_with_optional_inline_arg(args, index, PUSH_OPTS_WITH_ARG)
            else:
                index += 1
            continue
        result.append(arg)
        index += 1
    return result


def normalize_ref(refspec: str) -> str:
    refspec = refspec.lstrip("+")
    if ":" in refspec:
        refspec = refspec.rsplit(":", 1)[1]
    for prefix in ("refs/heads/", "heads/"):
        if refspec.startswith(prefix):
            refspec = refspec[len(prefix) :]
    return refspec


def explicit_targets(invocation: GitInvocation) -> list[str]:
    positionals = push_positionals(invocation.args)
    if len(positionals) <= 1:
        return []
    return [normalize_ref(refspec) for refspec in positionals[1:]]


def current_branch(cwd: str | None) -> str:
    cmd = ["git"]
    if cwd:
        cmd.extend(["-C", cwd])
    cmd.extend(["rev-parse", "--abbrev-ref", "HEAD"])
    try:
        return subprocess.check_output(cmd, text=True, stderr=subprocess.DEVNULL).strip()
    except Exception:
        return ""


def has_bare_force(args: list[str]) -> bool:
    for arg in args:
        if arg.startswith("--force-with-lease"):
            continue
        if arg == "--force" or arg.startswith("--force="):
            return True
        if arg == "-f":
            return True
    return False


def has_force_lease(args: list[str]) -> bool:
    return any(arg.startswith("--force-with-lease") for arg in args)


def mode_has_git_push(command: str) -> int:
    return 0 if push_invocations(command) else 1


def mode_protected_push_target(command: str) -> int:
    for invocation in push_invocations(command):
        targets = explicit_targets(invocation)
        if targets:
            for target in targets:
                if target in {"master", "main"}:
                    print(target)
                    return 0
        else:
            branch = current_branch(invocation.cwd)
            if branch in {"master", "main"}:
                print(branch)
                return 0
    return 1


def mode_unsafe_git_alias(command: str) -> int:
    if has_inline_alias_override(command):
        return 0
    return 0 if any(inv.subcommand in UNSAFE_ALIAS_SUBCOMMANDS for inv in git_invocations(command)) else 1


def mode_push_has_bare_force(command: str) -> int:
    for invocation in push_invocations(command):
        if has_bare_force(invocation.args):
            return 0
    return 1


def mode_force_lease_non_work(command: str) -> int:
    for invocation in push_invocations(command):
        if not has_force_lease(invocation.args):
            continue
        targets = explicit_targets(invocation)
        target = targets[-1] if targets else current_branch(invocation.cwd)
        if not target.startswith(WORK_BRANCH_PREFIXES):
            print(target)
            return 0
    return 1


def has_ff_only(args: list[str]) -> bool:
    return any(arg == "--ff-only" or arg.startswith("--ff-only=") for arg in args)


def has_rebase_option(args: list[str]) -> bool:
    return any(
        arg == "--rebase" or arg.startswith("--rebase=") or arg == "-r"
        for arg in args
    )


def is_task_branch(cwd: str | None) -> bool:
    return current_branch(cwd).startswith(WORK_BRANCH_PREFIXES)


def mode_task_acceptance_git(command: str) -> int:
    for invocation in git_invocations(command):
        if invocation.subcommand == "commit":
            print("git commit")
            return 0
        if invocation.subcommand == "merge" and not has_ff_only(invocation.args):
            if "origin/master" in invocation.args and not is_task_branch(invocation.cwd):
                continue
            print("git merge origin/master" if "origin/master" in invocation.args else "git merge")
            return 0
        if invocation.subcommand == "pull" and not has_ff_only(invocation.args) and not has_rebase_option(invocation.args):
            if not is_task_branch(invocation.cwd):
                continue
            print("git pull")
            return 0
    return 1


def mode_publish_review_mode(command: str) -> int:
    matched = False
    for invocation in command_invocations(command):
        if posixpath.basename(invocation.executable) != "publish-review-package.sh":
            continue
        matched = True
        args = invocation.args
        create_count = args.count("--create-pr")
        update_positions = [index for index, arg in enumerate(args) if arg == "--update-pr"]
        if create_count == 1 and not update_positions:
            print("create")
            return 0
        if create_count == 0 and len(update_positions) == 1:
            index = update_positions[0]
            if index + 1 < len(args) and args[index + 1].isdigit() and int(args[index + 1]) > 0:
                print("update")
                return 0
        print("invalid")
        return 0
    return 1 if not matched else 0


def mode_dangerous_pattern(command: str) -> int:
    for invocation in git_invocations(command):
        args = invocation.args
        if invocation.subcommand == "reset" and "--hard" in args:
            print("git reset --hard")
            return 0
        if invocation.subcommand == "clean" and any(arg.startswith("-") and "f" in arg for arg in args):
            print("git clean -f")
            return 0
        if invocation.subcommand == "branch" and "-D" in args:
            print("git branch -D")
            return 0
        if invocation.subcommand == "checkout" and "." in args:
            print("git checkout .")
            return 0
        if invocation.subcommand == "restore" and "." in args:
            print("git restore .")
            return 0
    return 1


def mode_invokes(command: str, executable_name: str, required_arg: str | None = None) -> int:
    return 0 if invokes_command(command, executable_name, required_arg) else 1


def command_from_stdin() -> str:
    return sys.stdin.read()


def main() -> int:
    if len(sys.argv) < 2:
        return 2
    mode = sys.argv[1]
    if mode == "value":
        if len(sys.argv) != 3:
            return 2
        return value(sys.argv[2])
    if mode == "normalize-codex-apply-patch":
        if len(sys.argv) != 2:
            return 2
        return normalize_codex_apply_patch()

    command = command_from_stdin()
    if mode == "has-git-push":
        return mode_has_git_push(command)
    if mode == "unsafe-git-alias":
        return mode_unsafe_git_alias(command)
    if mode == "protected-push-target":
        return mode_protected_push_target(command)
    if mode == "push-has-bare-force":
        return mode_push_has_bare_force(command)
    if mode == "force-lease-non-work":
        return mode_force_lease_non_work(command)
    if mode == "task-acceptance-git":
        return mode_task_acceptance_git(command)
    if mode == "publish-review-mode":
        return mode_publish_review_mode(command)
    if mode == "dangerous-pattern":
        return mode_dangerous_pattern(command)
    if mode == "invokes":
        if len(sys.argv) not in {3, 4}:
            return 2
        required_arg = sys.argv[3] if len(sys.argv) == 4 else None
        return mode_invokes(command, sys.argv[2], required_arg)
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
