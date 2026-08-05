#!/usr/bin/env bash
# .claude/hooks/ PreToolUse 拦截器的纯 bash 测试夹具。
#
# 设计契约（与 hook 一致）：
#   - 零测试框架依赖（不引 bats/jq）；安全敏感 hook 可复用 Python helper 做真实 JSON/shell 解析。
#   - seam = stdin JSON → exit code + stderr 黑盒边界（hook 本身即 public boundary）。
#   - 退出码：全用例过 → 0；任一失败 → 非 0。CI/手测一键判过。
#
# 跑法：bash scripts/test-hooks.sh
# 可选：HOOK_DIR=/path/to/hooks bash scripts/test-hooks.sh
#
# 为什么存在：PR #11 的 block-issue-without-repo.sh 首版正则只匹配 string，
# 漏了 MCP schema 里 project_id 的 number 形态，「三场景空跑通过」是假绿
# （IJZ5WA 复现）。手写测试输入凭直觉写字符串、不对照真实 schema 类型是根因。
# 本夹具强制：输入 JSON 字段类型须以 MCP tools/list schema 为准。

set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK_DIR="${HOOK_DIR:-"$REPO_ROOT/.claude/hooks"}"
HOOK_DIR="$(cd "$HOOK_DIR" && pwd)"
CODEX_HOOKS_JSON="$REPO_ROOT/.codex/hooks.json"
CODEX_WRITE_PROBE="$REPO_ROOT/scripts/probe-codex-write-hook.sh"
HOOK_CONTRACT_CHECKER="$REPO_ROOT/scripts/check-hook-contracts.py"
HOOK_CLOSED_LOOP_CHECKER="$REPO_ROOT/scripts/check-hook-closed-loop.py"
AUTH_SCRIPT="$REPO_ROOT/scripts/manage-agent-authorization.sh"
REAL_GIT="$(command -v git)"
ACTION_TEST_ROOT=""
PUBLISH_TEST_ROOT=""
SAVED_CLAUDE_PROJECT_DIR=""
SAVED_PUBLISH_PROJECT_DIR=""
ORIGINAL_CLAUDE_PROJECT_DIR="${CLAUDE_PROJECT_DIR:-}"
HOOK_AUDIT_TEST_ROOT="$(mktemp -d)"
"$REAL_GIT" -C "$HOOK_AUDIT_TEST_ROOT" init -q
CLAUDE_PROJECT_DIR="$HOOK_AUDIT_TEST_ROOT"
export CLAUDE_PROJECT_DIR

# ── git stub（隔离 git rev-parse，不碰真实仓库）────────────────
# push-to-master / dangerous-git 的「无显式 refspec → 查当前分支」分支，
# 用 PATH 注入临时 fake git：只响应 rev-parse --abbrev-ref HEAD → $FAKE_BRANCH。
STUB_DIR=""
SAVED_PATH="$PATH"

setup_git_stub() {
  STUB_DIR="$(mktemp -d)"
  cat >"${STUB_DIR}/git" <<'EOF'
#!/usr/bin/env bash
# fake git：解析可选 -C <dir>。无 -C 走全局 fallback（保 push-to-master 等旧 slice 兼容）；
# 有 -C 按 FAKE_BRANCH_MAP / FAKE_TOPLEVEL_MAP（每行 prefix<TAB>value，路径前缀匹配）返回；
# 有 -C 但未命中 MAP → 空输出 exit 1（模拟该目录不属任何工作树 / 无分支，供 hook 走仓库外放行）。
git_dir=""
if [ "$1" = "-C" ]; then
  git_dir="$2"; shift 2
fi
# lookup_map <map-text> <query-dir>：每行 prefix<TAB>value，query 前缀命中 prefix → echo value 返回 0
lookup_map() {
  while IFS=$'\t' read -r prefix value; do
    [ -z "$prefix" ] && continue
    case "$2" in "$prefix"*) echo "$value"; return 0 ;; esac
  done < <(printf '%s\n' "$1")
  return 1
}
if [ -z "$git_dir" ] && [ "$1" = "rev-parse" ] && [ "$2" = "--abbrev-ref" ] && [ "$3" = "HEAD" ]; then
  echo "${FAKE_BRANCH:-master}"
  exit 0
fi
if [ "$1" = "symbolic-ref" ] && [ "$2" = "--short" ] && [ "$3" = "HEAD" ]; then
  if [ -n "$git_dir" ] && [ -n "${FAKE_BRANCH_MAP:-}" ] && lookup_map "$FAKE_BRANCH_MAP" "$git_dir"; then exit 0; fi
  if [ -n "$git_dir" ]; then exit 1; fi
  echo "${FAKE_BRANCH:-master}"
  exit 0
fi
if [ "$1" = "rev-parse" ] && [ "$2" = "--show-toplevel" ]; then
  if [ -n "$git_dir" ] && [ -n "${FAKE_TOPLEVEL_MAP:-}" ] && lookup_map "$FAKE_TOPLEVEL_MAP" "$git_dir"; then exit 0; fi
  if [ -n "$git_dir" ]; then exit 1; fi
  echo "${FAKE_GIT_TOPLEVEL:-$PWD}"
  exit 0
fi
# 其它子命令不归本 stub 管，exit 0 空输出（hook 不依赖）
exit 0
EOF
  chmod +x "${STUB_DIR}/git"
  export PATH="${STUB_DIR}:${SAVED_PATH}"
}

teardown_git_stub() {
  if [ -n "$STUB_DIR" ] && [ -d "$STUB_DIR" ]; then
    rm -rf "$STUB_DIR"
  fi
  PATH="$SAVED_PATH"
  export PATH
}

# ── 计数 ────────────────────────────────────────────────────────
PASS=0
FAIL=0
FAILURES=()

# ── helper ──────────────────────────────────────────────────────
# run_hook <hook_name> <json>
# 喂 stdin JSON，捕获 exit code 到 $RUN_EXIT、stdout 到 $RUN_STDOUT、stderr 到 $RUN_STDERR。
run_hook() {
  local hook="$1"; shift
  local json="$1"; shift
  local tmp_out
  local tmp_err
  tmp_out="$(mktemp)"
  tmp_err="$(mktemp)"
  printf '%s' "$json" | bash "${HOOK_DIR}/${hook}" >"$tmp_out" 2>"$tmp_err"
  RUN_EXIT=$?
  RUN_STDOUT="$(cat "$tmp_out")"
  RUN_STDERR="$(cat "$tmp_err")"
  rm -f "$tmp_out"
  rm -f "$tmp_err"
}

# run_command_hook <command> <json>
# 喂 stdin JSON 到 settings/hooks.json 中的 command 字符串，捕获边界输出。
run_command_hook() {
  local command="$1"; shift
  local json="$1"; shift
  local tmp_out
  local tmp_err
  tmp_out="$(mktemp)"
  tmp_err="$(mktemp)"
  printf '%s' "$json" | eval "$command" >"$tmp_out" 2>"$tmp_err"
  RUN_EXIT=$?
  RUN_STDOUT="$(cat "$tmp_out")"
  RUN_STDERR="$(cat "$tmp_err")"
  rm -f "$tmp_out"
  rm -f "$tmp_err"
}

run_authorization() {
  local tmp_out
  local tmp_err
  tmp_out="$(mktemp)"
  tmp_err="$(mktemp)"
  bash "$AUTH_SCRIPT" "$@" >"$tmp_out" 2>"$tmp_err"
  RUN_EXIT=$?
  RUN_STDOUT="$(cat "$tmp_out")"
  RUN_STDERR="$(cat "$tmp_err")"
  rm -f "$tmp_out" "$tmp_err"
}

run_authorization_helper() {
  local tmp_out tmp_err
  tmp_out="$(mktemp)"
  tmp_err="$(mktemp)"
  python3 "$REPO_ROOT/.claude/hooks/lib/authorization.py" "$@" >"$tmp_out" 2>"$tmp_err"
  RUN_EXIT=$?
  RUN_STDOUT="$(cat "$tmp_out")"
  RUN_STDERR="$(cat "$tmp_err")"
  rm -f "$tmp_out" "$tmp_err"
}

# assert_exit <expected_exit> <label>
assert_exit() {
  local expect="$1"; shift
  local label="$1"; shift
  if [ "$RUN_EXIT" = "$expect" ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    FAILURES+=("[${label}] exit=${RUN_EXIT} 期望=${expect}")
  fi
}

# assert_stderr_has <substring> <label>
assert_stderr_has() {
  local needle="$1"; shift
  local label="$1"; shift
  if printf '%s' "$RUN_STDERR" | grep -qF -- "$needle"; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    FAILURES+=("[${label}] stderr 未含 \"${needle}\" 实际=${RUN_STDERR}")
  fi
}

assert_stdout_has() {
  local needle="$1"; shift
  local label="$1"; shift
  if printf '%s' "$RUN_STDOUT" | grep -qF -- "$needle"; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    FAILURES+=("[${label}] stdout 未含 \"${needle}\" 实际=${RUN_STDOUT}")
  fi
}

assert_stdout_starts_with() {
  local prefix="$1"; shift
  local label="$1"; shift
  case "$RUN_STDOUT" in
    "$prefix"*)
      PASS=$((PASS + 1))
      ;;
    *)
      FAIL=$((FAIL + 1))
      FAILURES+=("[${label}] stdout 未以 \"${prefix}\" 开头 实际=${RUN_STDOUT}")
      ;;
  esac
}

assert_stdout_empty() {
  local label="$1"; shift
  if [ -z "$RUN_STDOUT" ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    FAILURES+=("[${label}] stdout 应为空，实际=${RUN_STDOUT}")
  fi
}

assert_stderr_empty() {
  local label="$1"; shift
  if [ -z "$RUN_STDERR" ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    FAILURES+=("[${label}] stderr 应为空，实际=${RUN_STDERR}")
  fi
}

assert_exit_nonzero() {
  local label="$1"; shift
  if [ "$RUN_EXIT" -ne 0 ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    FAILURES+=("[${label}] exit=${RUN_EXIT} 期望非零")
  fi
}

publish_marker_path() {
  local branch="${1:-feature/x}"
  local slug="$(printf '%s' "$branch" | tr '/' '%')"
  local root="${PUBLISH_TEST_ROOT:-$REPO_ROOT}"
  local common="$("$REAL_GIT" -C "$root" rev-parse --git-common-dir 2>/dev/null || true)"
  case "$common" in
    "") common="$root/.git" ;;
    /*) ;;
    *)  common="$root/$common" ;;
  esac
  printf '%s/agent-release-review-package-%s' "$common" "$slug"
}

write_publish_marker() {
  local branch="$1"; shift
  local target="${1:-master}"; shift || true
  local created_at="${1:-$(date +%s)}"; shift || true
  local marker
  marker="$(publish_marker_path "$branch")"
  mkdir -p "$(dirname "$marker")"
  cat >"$marker" <<EOF
branch=$branch
target=$target
created_at=$created_at
EOF
}

remove_publish_marker() {
  local branch="${1:-feature/x}"
  rm -f "$(publish_marker_path "$branch")"
}

authorization_marker_path() {
  local action="$1"
  local enterprise_id="$2"
  local project_id="$3"
  local subject="$4"
  local root common digest
  root="${ACTION_TEST_ROOT:-$REPO_ROOT}"
  common="$("$REAL_GIT" -C "$root" rev-parse --git-common-dir)"
  case "$common" in /*) ;; *) common="$root/$common" ;; esac
  digest="$(printf '%s\n%s\n%s\n%s\n' "$action" "$enterprise_id" "$project_id" "$subject" | "$REAL_GIT" -C "$root" hash-object --stdin)"
  printf '%s/agent-action-authorizations/%s' "$common" "$digest"
}

authorization_claim_path() {
  printf '%s.claim' "$(authorization_marker_path "$@")"
}

write_action_marker() {
  local action="$1"
  local enterprise_id="$2"
  local project_id="$3"
  local subject="$4"
  local created_at="${5:-$(date +%s)}"
  local marker
  marker="$(authorization_marker_path "$action" "$enterprise_id" "$project_id" "$subject")"
  mkdir -p "$(dirname "$marker")"
  cat >"$marker" <<EOF
version=1
action=$action
enterprise_id=$enterprise_id
project_id=$project_id
subject=$subject
created_at=$created_at
EOF
  chmod 600 "$marker"
}

remove_all_action_markers() {
  local marker
  marker="$(authorization_marker_path _ _ _ _)"
  rm -rf "$(dirname "$marker")"
}

setup_action_test_repo() {
  SAVED_CLAUDE_PROJECT_DIR="${CLAUDE_PROJECT_DIR:-}"
  ACTION_TEST_ROOT="$(mktemp -d)"
  "$REAL_GIT" -C "$ACTION_TEST_ROOT" init -q
  mkdir -p "$ACTION_TEST_ROOT/.claude/hooks/lib" "$ACTION_TEST_ROOT/scripts"
  cp "$REPO_ROOT/.claude/hooks/lib/authorization.py" "$ACTION_TEST_ROOT/.claude/hooks/lib/authorization.py"
  cp "$REPO_ROOT/scripts/manage-agent-authorization.sh" "$ACTION_TEST_ROOT/scripts/manage-agent-authorization.sh"
  chmod +x "$ACTION_TEST_ROOT/.claude/hooks/lib/authorization.py" "$ACTION_TEST_ROOT/scripts/manage-agent-authorization.sh"
  AUTH_SCRIPT="$ACTION_TEST_ROOT/scripts/manage-agent-authorization.sh"
  CLAUDE_PROJECT_DIR="$ACTION_TEST_ROOT"
  export ACTION_TEST_ROOT AUTH_SCRIPT CLAUDE_PROJECT_DIR
}

teardown_action_test_repo() {
  if [ -n "$SAVED_CLAUDE_PROJECT_DIR" ]; then
    CLAUDE_PROJECT_DIR="$SAVED_CLAUDE_PROJECT_DIR"
    export CLAUDE_PROJECT_DIR
  else
    unset CLAUDE_PROJECT_DIR
  fi
  AUTH_SCRIPT="$REPO_ROOT/scripts/manage-agent-authorization.sh"
  rm -rf "$ACTION_TEST_ROOT"
  ACTION_TEST_ROOT=""
  SAVED_CLAUDE_PROJECT_DIR=""
  export ACTION_TEST_ROOT AUTH_SCRIPT SAVED_CLAUDE_PROJECT_DIR
}

setup_publish_test_repo() {
  SAVED_PUBLISH_PROJECT_DIR="${CLAUDE_PROJECT_DIR:-}"
  PUBLISH_TEST_ROOT="$(mktemp -d)"
  "$REAL_GIT" -C "$PUBLISH_TEST_ROOT" init -q
  CLAUDE_PROJECT_DIR="$PUBLISH_TEST_ROOT"
  export PUBLISH_TEST_ROOT CLAUDE_PROJECT_DIR
}

teardown_publish_test_repo() {
  if [ -n "$SAVED_PUBLISH_PROJECT_DIR" ]; then
    CLAUDE_PROJECT_DIR="$SAVED_PUBLISH_PROJECT_DIR"
    export CLAUDE_PROJECT_DIR
  else
    unset CLAUDE_PROJECT_DIR
  fi
  rm -rf "$PUBLISH_TEST_ROOT"
  PUBLISH_TEST_ROOT=""
  SAVED_PUBLISH_PROJECT_DIR=""
  export PUBLISH_TEST_ROOT SAVED_PUBLISH_PROJECT_DIR
}

assert_stdout_not_has() {
  local needle="$1"; shift
  local label="$1"; shift
  if printf '%s' "$RUN_STDOUT" | grep -qF -- "$needle"; then
    FAIL=$((FAIL + 1))
    FAILURES+=("[${label}] stdout 不应含 \"${needle}\" 实际=${RUN_STDOUT}")
  else
    PASS=$((PASS + 1))
  fi
}

assert_file_exists() {
  local path="$1"; shift
  local label="$1"; shift
  if [ -f "$path" ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    FAILURES+=("[${label}] 文件不存在：${path}")
  fi
}

assert_file_missing() {
  local path="$1"; shift
  local label="$1"; shift
  if [ ! -e "$path" ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    FAILURES+=("[${label}] 文件仍存在：${path}")
  fi
}

assert_file_mode_600() {
  local path="$1"; shift
  local label="$1"; shift
  local mode
  mode="$(python3 - "$path" <<'PY'
import os, stat, sys
print(oct(stat.S_IMODE(os.stat(sys.argv[1]).st_mode)))
PY
)"
  if [ "$mode" = "0o600" ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    FAILURES+=("[${label}] 文件权限=${mode} 期望=0o600：${path}")
  fi
}

assert_file_has_text() {
  local path="$1"; shift
  local needle="$1"; shift
  local label="$1"; shift
  if grep -qF -- "$needle" "$path"; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    FAILURES+=("[${label}] ${path} 未含 \"${needle}\"")
  fi
}

assert_markdown_section_has_text() {
  local path="$1"; shift
  local heading="$1"; shift
  local needle="$1"; shift
  local label="$1"; shift
  if awk -v heading="$heading" -v needle="$needle" '
    $0 == heading { in_section = 1; next }
    in_section && /^## / { in_section = 0 }
    in_section && index($0, needle) { found = 1 }
    END { exit found ? 0 : 1 }
  ' "$path"; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    FAILURES+=("[${label}] ${path} 的 ${heading} 章节未含 \"${needle}\"")
  fi
}

assert_file_not_has_text() {
  local path="$1"; shift
  local needle="$1"; shift
  local label="$1"; shift
  if grep -qF -- "$needle" "$path"; then
    FAIL=$((FAIL + 1))
    FAILURES+=("[${label}] ${path} 不应含 \"${needle}\"")
  else
    PASS=$((PASS + 1))
  fi
}

assert_file_not_matches() {
  local path="$1"; shift
  local pattern="$1"; shift
  local label="$1"; shift
  if grep -qE -- "$pattern" "$path"; then
    FAIL=$((FAIL + 1))
    FAILURES+=("[${label}] ${path} 不应匹配正则 ${pattern}")
  else
    PASS=$((PASS + 1))
  fi
}

assert_git_ignored() {
  local path="$1"; shift
  local label="$1"; shift
  if git check-ignore -q --no-index "$path"; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    FAILURES+=("[${label}] 应被 gitignore 忽略但未被忽略：${path}")
  fi
}

assert_git_not_ignored() {
  local path="$1"; shift
  local label="$1"; shift
  if git check-ignore -q --no-index "$path"; then
    FAIL=$((FAIL + 1))
    FAILURES+=("[${label}] 不应被 gitignore 忽略但已被忽略：${path}")
  else
    PASS=$((PASS + 1))
  fi
}

# ── hook 审计日志辅助（IK10CW）──────────────────────────────────
# audit_log_file_path <project_dir> <hook_name> <suffix>
# 解析 git common dir 下的审计日志路径（与 lib/hook_audit.py 同源）。
audit_log_file_path() {
  local project_dir="$1" hook_name="$2" suffix="$3"
  local common safe
  common="$("$REAL_GIT" -C "$project_dir" rev-parse --git-common-dir 2>/dev/null || true)"
  case "$common" in
    "") common="$project_dir/.git" ;;
    /*) ;;
    *)  common="$project_dir/$common" ;;
  esac
  safe="$(printf '%s' "$hook_name" | tr '/' '_')"
  printf '%s/hook-audit/%s.log%s' "$common" "$safe" "$suffix"
}

# audit_log_path <project_dir> <hook_name>
audit_log_path() {
  audit_log_file_path "$1" "$2" ""
}

# audit_log_archive_path <project_dir> <hook_name>
audit_log_archive_path() {
  audit_log_file_path "$1" "$2" ".1"
}

# assert_audit_has_field <log_path> <json_field> <expected_value> <label>
# 断言活跃日志至少有一行含 field=expected_value（用 python 解析 JSON）。
assert_audit_has_field() {
  local log_path="$1" field="$2" expected="$3" label="$4"
  if python3 - "$log_path" "$field" "$expected" <<'PY'
import json, sys
log_path, field, expected = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    with open(log_path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            obj = json.loads(line)
            if str(obj.get(field, "")) == expected:
                sys.exit(0)
except FileNotFoundError:
    pass
sys.exit(1)
PY
  then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    FAILURES+=("[${label}] 日志 ${log_path} 未找到 ${field}=${expected}")
  fi
}

# assert_audit_record_field <log_path> <tool_use_id> <json_field> <expected_value> <label>
# 断言指定 tool_use_id 的记录含 field=expected_value，避免跨记录拼出假阳性。
assert_audit_record_field() {
  local log_path="$1" tool_use_id="$2" field="$3" expected="$4" label="$5"
  if python3 - "$log_path" "$tool_use_id" "$field" "$expected" <<'PY'
import json, sys
log_path, tool_use_id, field, expected = sys.argv[1:]
try:
    with open(log_path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            record = json.loads(line)
            if record.get("tool_use_id") == tool_use_id and str(record.get(field, "")) == expected:
                raise SystemExit(0)
except FileNotFoundError:
    pass
raise SystemExit(1)
PY
  then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    FAILURES+=("[${label}] 日志 ${log_path} 未找到 tool_use_id=${tool_use_id} 且 ${field}=${expected}")
  fi
}

# assert_audit_line_count <log_path> <expected_count> <label>
assert_audit_line_count() {
  local log_path="$1" expected="$2" label="$3"
  local actual=0
  if [ -f "$log_path" ]; then
    actual=$(grep -c '' "$log_path" 2>/dev/null || echo 0)
  fi
  if [ "$actual" = "$expected" ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    FAILURES+=("[${label}] 日志行数=${actual} 期望=${expected} (${log_path})")
  fi
}

# assert_audit_not_tracked <project_dir> <hook_name> <label>
# 断言 active/archive 位于 git common dir 且不出现在 Git 视图中。
assert_audit_not_tracked() {
  local project_dir="$1" hook_name="$2" label="$3"
  local common active archive status tracked
  common="$("$REAL_GIT" -C "$project_dir" rev-parse --git-common-dir 2>/dev/null || true)"
  case "$common" in
    "") common="$project_dir/.git" ;;
    /*) ;;
    *)  common="$project_dir/$common" ;;
  esac
  active="$(audit_log_path "$project_dir" "$hook_name")"
  archive="$(audit_log_archive_path "$project_dir" "$hook_name")"
  status="$("$REAL_GIT" -C "$project_dir" status --porcelain --untracked-files=all 2>/dev/null || true)"
  tracked="$("$REAL_GIT" -C "$project_dir" ls-files 2>/dev/null || true)"
  case "$active:$archive" in
    "$common"/hook-audit/*:"$common"/hook-audit/*) ;;
    *)
      FAIL=$((FAIL + 1))
      FAILURES+=("[${label}] active/archive 未位于 git common dir: ${active} / ${archive}")
      return
      ;;
  esac
  if printf '%s\n%s\n' "$status" "$tracked" | grep -qF 'hook-audit'; then
    FAIL=$((FAIL + 1))
    FAILURES+=("[${label}] hook-audit 出现在 git status/ls-files（不应被跟踪）")
  else
    PASS=$((PASS + 1))
  fi
}

assert_codex_hooks_valid() {
  local label="$1"; shift
  local tmp_err
  tmp_err="$(mktemp)"
  python3 - "$REPO_ROOT/.claude/settings.json" "$CODEX_HOOKS_JSON" > /dev/null 2>"$tmp_err" <<'PY'
import json
import os
import re
import shlex
import sys
from pathlib import Path

claude_path = Path(sys.argv[1])
codex_path = Path(sys.argv[2])
claude = json.loads(claude_path.read_text())
codex = json.loads(codex_path.read_text())

def shape(items):
    return [(item["matcher"], len(item.get("hooks", []))) for item in items]

def claude_script(command):
    match = re.search(r"\.claude/hooks/([^\"'\s]+\.sh)", command)
    return match.group(1) if match else None

def codex_script(command):
    if "run-claude-pretool.sh" not in command:
        if ".codex/hooks/" in command:
            raise SystemExit(f"Codex command points at copied .codex/hooks implementation: {command}")
        if ".claude/hooks/" in command:
            raise SystemExit(f"Codex command bypasses wrapper: {command}")
        return None
    parts = shlex.split(command)
    scripts = [
        os.path.basename(part)
        for part in parts
        if part.endswith(".sh") and os.path.basename(part) != "run-claude-pretool.sh"
    ]
    if len(scripts) != 1:
        raise SystemExit(f"Codex wrapper command must name exactly one hook script: {command}")
    return scripts[0]

script_count = 0
for event in ("PreToolUse", "PostToolUse"):
    claude_items = claude["hooks"].get(event, [])
    codex_items = codex["hooks"].get(event, [])
    if event == "PreToolUse":
        master_edit_items = [
            item for item in codex_items if item.get("matcher") == "Edit|Write"
        ]
        if len(master_edit_items) != 1:
            raise SystemExit(
                "Codex must register exactly one Edit|Write matcher for block-master-edit.sh"
            )
        master_edit_scripts = [
            script
            for hook in master_edit_items[0].get("hooks", [])
            if hook.get("type") == "command"
            for script in [codex_script(hook["command"])]
            if script
        ]
        if master_edit_scripts != ["block-master-edit.sh"]:
            raise SystemExit(
                "Codex Edit|Write matcher must point to shared block-master-edit.sh"
            )
        script_count += len(master_edit_scripts)

        # 提醒型 gate 不属于平台中立契约；Codex 的 Edit|Write 由专用适配器接入共享 Gate。
        claude_items = [
            it for it in claude_items if it["matcher"] not in ("Grep|Glob", "Edit|Write")
        ]
        codex_items = [
            it for it in codex_items if it["matcher"] != "Edit|Write"
        ]
    if shape(claude_items) != shape(codex_items):
        raise SystemExit(
            f"{event} matcher/hook shape mismatch: claude={shape(claude_items)} codex={shape(codex_items)}"
        )
    for index, (claude_item, codex_item) in enumerate(zip(claude_items, codex_items)):
        claude_scripts = [
            script
            for hook in claude_item.get("hooks", [])
            if hook.get("type") == "command"
            for script in [claude_script(hook["command"])]
            if script
        ]
        codex_scripts = [
            script
            for hook in codex_item.get("hooks", [])
            if hook.get("type") == "command"
            for script in [codex_script(hook["command"])]
            if script
        ]
        if claude_scripts != codex_scripts:
            raise SystemExit(
                f"script mismatch at {event}[{index}] matcher={claude_item['matcher']}: "
                f"claude={claude_scripts} codex={codex_scripts}"
            )
        script_count += len(codex_scripts)

pre_matchers = [item["matcher"] for item in codex["hooks"]["PreToolUse"]]
required_pre = {
    "Bash",
    "mcp__gitee-ent__create_enterprise_repo_pull",
    "mcp__gitee-ent__merge_enterprise_pull",
    "mcp__gitee-ent__create_enterprise_repo_release",
    "mcp__gitee-ent__create_enterprise_issue",
    "mcp__gitee-ent__update_enterprise_issue",
}
missing = sorted(required_pre - set(pre_matchers))
if missing:
    raise SystemExit(f"missing Codex PreToolUse matcher(s): {missing}")

post_matchers = {item["matcher"] for item in codex["hooks"].get("PostToolUse", [])}
required_post = {
    "mcp__gitee-ent__create_enterprise_repo_pull",
    "mcp__gitee-ent__merge_enterprise_pull",
    "mcp__gitee-ent__create_enterprise_repo_release",
}
missing = sorted(required_post - post_matchers)
if missing:
    raise SystemExit(f"missing Codex PostToolUse matcher(s): {missing}")

if script_count == 0:
    raise SystemExit("no Codex script hook commands found")
PY
  local exit_code=$?
  if [ "$exit_code" = 0 ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    FAILURES+=("[${label}] Codex hooks JSON 校验失败：$(cat "$tmp_err")")
  fi
  rm -f "$tmp_err"
}

run_hook_contract_check() {
  local tmp_out tmp_err
  tmp_out="$(mktemp)"
  tmp_err="$(mktemp)"
  python3 "$HOOK_CONTRACT_CHECKER" "$@" >"$tmp_out" 2>"$tmp_err"
  RUN_EXIT=$?
  RUN_STDOUT="$(cat "$tmp_out")"
  RUN_STDERR="$(cat "$tmp_err")"
  rm -f "$tmp_out" "$tmp_err"
}

assert_hook_contract_drift_case() {
  local fixture_dir="$1"; shift
  local zcode_fixture="$1"; shift
  local claude_fixture="$1"; shift
  local codex_fixture="$1"; shift
  local platform="$1"; shift
  local drift_mode="$1"; shift
  local source drift_fixture drift_label
  local expected_matcher="Edit|Write"
  local expected_gate="block-master-edit.sh"
  local zcode_candidate="$zcode_fixture"
  local claude_candidate="$claude_fixture"
  local codex_candidate="$codex_fixture"

  drift_fixture="$fixture_dir/${platform// /-}-${drift_mode}-drift.json"
  case "$platform" in
    "ZCode") source="$zcode_fixture"; zcode_candidate="$drift_fixture" ;;
    "Claude Code") source="$claude_fixture"; claude_candidate="$drift_fixture" ;;
    "Codex") source="$codex_fixture"; codex_candidate="$drift_fixture" ;;
  esac
  cp "$source" "$drift_fixture"
  python3 - "$drift_fixture" "$platform" "$drift_mode" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
platform = sys.argv[2]
drift_mode = sys.argv[3]
config = json.loads(path.read_text())
hooks = config["hooks"]["events"] if platform == "ZCode" else config["hooks"]
if drift_mode == "missing":
    hooks["PreToolUse"] = [
        item for item in hooks["PreToolUse"] if item.get("matcher") != "Edit|Write"
    ]
elif drift_mode == "extra":
    command = '"$CLAUDE_PROJECT_DIR"/.claude/hooks/block-master-edit.sh'
    if platform == "Codex":
        command = (
            'bash "$(git rev-parse --show-toplevel)/.codex/hooks/'
            'run-claude-pretool.sh" block-master-edit.sh'
        )
    hooks["PreToolUse"].append(
        {
            "matcher": "Read",
            "hooks": [{"type": "command", "command": command}],
        }
    )
elif drift_mode == "duplicate":
    for item in hooks["PreToolUse"]:
        if item.get("matcher") == "Edit|Write":
            item["hooks"].append(dict(item["hooks"][0]))
elif drift_mode == "wrong-wrapper":
    for item in hooks["PreToolUse"]:
        if item.get("matcher") == "Edit|Write":
            item["hooks"][0]["command"] = (
                "bash /tmp/run-claude-pretool.sh block-master-edit.sh"
            )
elif drift_mode == "unparsed-extra":
    command = "echo .claude/hooks/opaque-extra.sh"
    if platform == "Codex":
        command = "echo run-claude-pretool.sh opaque-extra.sh"
    hooks["PreToolUse"].append(
        {
            "matcher": "Bash",
            "hooks": [{"type": "command", "command": command}],
        }
    )
else:
    for item in hooks["PreToolUse"]:
        if item.get("matcher") == "Edit|Write":
            command = "echo .claude/hooks/block-master-edit.sh"
            if platform == "Codex":
                command = "echo run-claude-pretool.sh block-master-edit.sh"
            item["hooks"][0]["command"] = command
path.write_text(json.dumps(config, ensure_ascii=False, indent=2) + "\n")
PY
  run_hook_contract_check \
    --zcode "$zcode_candidate" \
    --claude "$claude_candidate" \
    --codex "$codex_candidate"
  case "$drift_mode" in
    missing) drift_label="缺失 Gate" ;;
    echo) drift_label="未执行 Gate" ;;
    extra) drift_label="多余阻断契约"; expected_matcher="Read" ;;
    duplicate) drift_label="重复挂载 Gate" ;;
    wrong-wrapper) drift_label="wrapper 路径错误" ;;
    unparsed-extra)
      drift_label="无法解析的额外 Gate"
      expected_matcher="Bash"
      expected_gate="opaque-extra.sh"
      ;;
  esac
  assert_exit_nonzero "contracts: ${platform} ${drift_label} 时失败"
  assert_stderr_has "$platform" "contracts: ${platform} ${drift_label} 诊断含平台"
  assert_stderr_has "PreToolUse" "contracts: ${platform} ${drift_label} 诊断含事件"
  assert_stderr_has "$expected_matcher" "contracts: ${platform} ${drift_label} 诊断含 matcher"
  assert_stderr_has "$expected_gate" "contracts: ${platform} ${drift_label} 诊断含 Gate"
}

assert_hook_contract_drift_detection() {
  local fixture_dir zcode_fixture claude_fixture codex_fixture
  local platform drift_mode
  fixture_dir="$(mktemp -d)"
  zcode_fixture="$fixture_dir/zcode.json"
  claude_fixture="$fixture_dir/claude.json"
  codex_fixture="$fixture_dir/codex.json"
  cp "$REPO_ROOT/.zcode/config.json" "$zcode_fixture"
  cp "$REPO_ROOT/.claude/settings.json" "$claude_fixture"
  cp "$CODEX_HOOKS_JSON" "$codex_fixture"

  run_hook_contract_check \
    --zcode "$zcode_fixture" \
    --claude "$claude_fixture" \
    --codex "$codex_fixture"
  assert_exit 0 "contracts: 三端临时基线有效"
  assert_stdout_empty "contracts: 有效基线 stdout 为空"
  assert_stderr_empty "contracts: 有效基线 stderr 为空"

  for drift_mode in missing echo extra duplicate unparsed-extra; do
    for platform in "ZCode" "Claude Code" "Codex"; do
      assert_hook_contract_drift_case \
        "$fixture_dir" \
        "$zcode_fixture" \
        "$claude_fixture" \
        "$codex_fixture" \
        "$platform" \
        "$drift_mode"
    done
  done
  assert_hook_contract_drift_case \
    "$fixture_dir" \
    "$zcode_fixture" \
    "$claude_fixture" \
    "$codex_fixture" \
    "Codex" \
    "wrong-wrapper"

  rm -rf "$fixture_dir"
}

assert_hook_audit_coverage_detection() {
  local fixture_dir zcode_fixture claude_fixture codex_fixture hooks_fixture
  fixture_dir="$(mktemp -d)"
  zcode_fixture="$fixture_dir/zcode.json"
  claude_fixture="$fixture_dir/claude.json"
  codex_fixture="$fixture_dir/codex.json"
  hooks_fixture="$fixture_dir/hooks"
  cp "$REPO_ROOT/.zcode/config.json" "$zcode_fixture"
  cp "$REPO_ROOT/.claude/settings.json" "$claude_fixture"
  cp "$CODEX_HOOKS_JSON" "$codex_fixture"
  cp -R "$REPO_ROOT/.claude/hooks" "$hooks_fixture"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$hooks_fixture/opaque-extra.sh"

  python3 - "$zcode_fixture" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
config = json.loads(path.read_text())
config["hooks"]["events"]["PreToolUse"].append(
    {
        "matcher": "Bash",
        "hooks": [
            {
                "type": "command",
                "command": '"${CLAUDE_PROJECT_DIR}"/.claude/hooks/opaque-extra.sh',
            }
        ],
    }
)
path.write_text(json.dumps(config, ensure_ascii=False, indent=2) + "\n")
PY

  run_hook_contract_check \
    --zcode "$zcode_fixture" \
    --claude "$claude_fixture" \
    --codex "$codex_fixture" \
    --hooks-dir "$hooks_fixture"
  assert_exit_nonzero "contracts: 已注册未接审计器的 Gate 时失败"
  assert_stderr_has "审计覆盖检查" "contracts: 未接审计器诊断含检查类别"
  assert_stderr_has "opaque-extra.sh" "contracts: 未接审计器诊断含 Gate"
  assert_stderr_has "未接入共享审计器" "contracts: 未接审计器诊断含根因"

  rm -rf "$fixture_dir"
}

assert_closed_loop_gate_drift_detection() {
  local fixture_dir zcode_fixture claude_fixture codex_fixture
  fixture_dir="$(mktemp -d)"
  zcode_fixture="$fixture_dir/zcode.json"
  claude_fixture="$fixture_dir/claude.json"
  codex_fixture="$fixture_dir/codex.json"
  cp "$REPO_ROOT/.zcode/config.json" "$zcode_fixture"
  cp "$REPO_ROOT/.claude/settings.json" "$claude_fixture"
  cp "$CODEX_HOOKS_JSON" "$codex_fixture"

  python3 - "$zcode_fixture" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
config = json.loads(path.read_text())
for item in config["hooks"]["events"]["PreToolUse"]:
    if item.get("matcher") == "Edit|Write":
        item["hooks"][0]["command"] = item["hooks"][0]["command"].replace(
            "block-master-edit.sh", "block-dangerous-git.sh"
        )
path.write_text(json.dumps(config, ensure_ascii=False, indent=2) + "\n")
PY

  run_command_hook \
    "python3 \"$HOOK_CLOSED_LOOP_CHECKER\" --zcode \"$zcode_fixture\" --claude \"$claude_fixture\" --codex \"$codex_fixture\"" \
    ""
  assert_exit_nonzero "closed-loop drift: Gate 不一致时失败"
  assert_stderr_has "stage=gate" "closed-loop drift: 诊断含失败阶段"
  assert_stderr_has "ZCode=block-dangerous-git.sh" "closed-loop drift: 诊断定位 ZCode Gate"
  assert_stderr_has "Claude Code=block-master-edit.sh" "closed-loop drift: 诊断定位 Claude Code Gate"
  assert_stderr_has "Codex=block-master-edit.sh" "closed-loop drift: 诊断定位 Codex Gate"

  rm -rf "$fixture_dir"
}

codex_command_for() {
  local script="$1"; shift
  local event="${1:-PreToolUse}"
  python3 - "$CODEX_HOOKS_JSON" "$script" "$event" <<'PY'
import json
import os
import shlex
import sys
from pathlib import Path

codex = json.loads(Path(sys.argv[1]).read_text())
wanted = sys.argv[2]
event = sys.argv[3]
matches = []
for item in codex["hooks"][event]:
    for hook in item.get("hooks", []):
        command = hook.get("command", "")
        if hook.get("type") != "command" or "run-claude-pretool.sh" not in command:
            continue
        parts = shlex.split(command)
        scripts = [
            os.path.basename(part)
            for part in parts
            if part.endswith(".sh") and os.path.basename(part) != "run-claude-pretool.sh"
        ]
        if scripts == [wanted]:
            matches.append(command)

if not matches:
    raise SystemExit(f"missing Codex command for {wanted}")
if len(set(matches)) != 1:
    raise SystemExit(f"ambiguous Codex commands for {wanted}: {matches}")
print(matches[0])
PY
}

CODEX_BLOCK_PUSH_CMD="$(codex_command_for block-push-to-master.sh)"
CODEX_DANGER_CMD="$(codex_command_for block-dangerous-git.sh)"
CODEX_ISSUE_CMD="$(codex_command_for block-issue-without-repo.sh)"
CODEX_RELEASE_CMD="$(codex_command_for confirm-release-action.sh)"
CODEX_RELEASE_POST_CMD="$(codex_command_for confirm-release-action.sh PostToolUse)"
CODEX_MASTER_EDIT_CMD="bash \"$REPO_ROOT/.codex/hooks/run-claude-pretool.sh\" block-master-edit.sh"

# ── 用例 ────────────────────────────────────────────────────────

# Slice 0 / 1 — block-squash-merge
# merge_method=merge → 放行（tracer bullet）
run_hook block-squash-merge.sh '{"tool_input":{"merge_method":"merge"}}'
assert_exit 0 "squash-merge: merge 放行"

# squash → 拦（exit 2 + stderr 提示 squash）
run_hook block-squash-merge.sh '{"tool_input":{"merge_method":"squash"}}'
assert_exit 2 "squash-merge: squash 拦截"
assert_stderr_has "squash" "squash-merge: squash 提示含 squash"

# rebase → 拦
run_hook block-squash-merge.sh '{"tool_input":{"merge_method":"rebase"}}'
assert_exit 2 "squash-merge: rebase 拦截"
assert_stderr_has "rebase" "squash-merge: rebase 提示含 rebase"

# 缺省（未传 merge_method，Gitee 默认 merge）→ 放行
run_hook block-squash-merge.sh '{"tool_input":{}}'
assert_exit 0 "squash-merge: 缺省放行"

# Slice 1.5 — confirm-release-action
RELEASE_HOOK=confirm-release-action.sh

# 非发布 Bash 命令 → 放行且不要求确认
run_hook "$RELEASE_HOOK" '{"tool_input":{"command":"git status --short"}}'
assert_exit 0 "release: 非发布 git status 放行"

# git push 修改远程 → 硬拦，必须走标准发布审查包入口
run_hook "$RELEASE_HOOK" '{"tool_input":{"command":"git push -u origin feature/x"}}'
assert_exit 2 "release: 直接 git push 被拦截"
assert_stderr_has "--create-pr" "release: 直接 git push 提示首次创建模式"
assert_stderr_has "--update-pr" "release: 直接 git push 提示已有 PR 更新模式"

# git 全局选项形式也应硬拦
run_hook "$RELEASE_HOOK" '{"tool_input":{"command":"git -C ../blue-whale-worktrees/task push origin feature/x"}}'
assert_exit 2 "release: git -C push 被拦截"
assert_stderr_has "直接 git push" "release: git -C push 提示直接 push"

# JSON 转义引号不能截断 command 后绕过 push 检测
run_hook "$RELEASE_HOOK" '{"tool_input":{"command":"echo \"ready\"; git push origin feature/x"}}'
assert_exit 2 "release: 转义引号后 git push 被拦截"
assert_stderr_has "直接 git push" "release: 转义引号后 git push 提示直接 push"

# bash -lc 嵌套 push 也不能绕过标准入口
run_hook "$RELEASE_HOOK" '{"tool_input":{"command":"bash -lc \"git push origin feature/x\""}}'
assert_exit 2 "release: bash -lc git push 被拦截"
assert_stderr_has "直接 git push" "release: bash -lc git push 提示直接 push"

# 直接 force-with-lease 也必须走标准入口，避免 PR 反馈后绕过发布确认
run_hook "$RELEASE_HOOK" '{"tool_input":{"command":"git push --force-with-lease origin feature/x"}}'
assert_exit 2 "release: 直接 force-with-lease push 被拦截"
assert_stderr_has "直接 git push" "release: 直接 force-with-lease push 提示直接 push"

# 旧项目发布脚本不由 Hook 弹窗；脚本自身会失败并提示新入口
run_hook "$RELEASE_HOOK" '{"tool_input":{"command":"scripts/publish-task-branch.sh"}}'
assert_exit 0 "release: publish-task-branch hook 放行"

# 新发布审查包入口缺授权参数 → 硬拦
run_hook "$RELEASE_HOOK" '{"tool_input":{"command":"scripts/publish-review-package.sh"}}'
assert_exit 2 "release: publish-review-package 缺参数被拦截"
assert_stderr_has "--user-authorized" "release: publish-review-package 缺参数提示授权参数"

# bash 包裹新发布审查包入口缺参数 → 仍应硬拦
run_hook "$RELEASE_HOOK" '{"tool_input":{"command":"bash scripts/publish-review-package.sh"}}'
assert_exit 2 "release: bash publish-review-package 缺参数被拦截"
assert_stderr_has "--user-authorized" "release: bash publish-review-package 缺参数提示授权参数"

# 新发布审查包入口带授权但缺模式 → fail closed
run_hook "$RELEASE_HOOK" '{"tool_input":{"command":"scripts/publish-review-package.sh --user-authorized"}}'
assert_exit 2 "release: publish-review-package 缺模式被拦截"
assert_stderr_has "--create-pr" "release: publish-review-package 缺模式提示 create"
assert_stderr_has "--update-pr" "release: publish-review-package 缺模式提示 update"

# create/update 显式单模式 + 授权 → 无交互放行
run_hook "$RELEASE_HOOK" '{"tool_input":{"command":"scripts/publish-review-package.sh --user-authorized --create-pr"}}'
assert_exit 0 "release: publish-review-package create 授权入口放行"
assert_stdout_empty "release: publish-review-package create 无交互输出"
run_hook "$RELEASE_HOOK" '{"tool_input":{"command":"scripts/publish-review-package.sh --user-authorized --update-pr 65"}}'
assert_exit 2 "release: publish-review-package update 缺 PR 快照被拦截"
assert_stderr_has "--pr-snapshot" "release: publish-review-package update 缺快照提示"
run_hook "$RELEASE_HOOK" '{"tool_input":{"command":"scripts/publish-review-package.sh --user-authorized --update-pr 65 --pr-snapshot /tmp/pr-65.json"}}'
assert_exit 0 "release: publish-review-package update 授权入口放行"
assert_stdout_empty "release: publish-review-package update 无交互输出"
run_hook "$RELEASE_HOOK" '{"tool_input":{"command":"scripts/publish-review-package.sh --user-authorized --create-pr --update-pr 65"}}'
assert_exit 2 "release: publish-review-package 双模式被拦截"

# 直接本地 commit / merge --no-ff 硬拦，要求改走标准入口。
run_hook "$RELEASE_HOOK" '{"tool_input":{"command":"git commit -m \"feat: task slice\""}}'
assert_exit 2 "release: 直接 git commit 硬拦"
assert_stderr_has "commit-task-for-review.sh -m" "release: 直接 git commit 指向标准入口"

# 裸 git commit --amend 同被拦（任何 commit 子命令归为 git commit），文案须同时指引首次 -m 与 review 后 --amend。
run_hook "$RELEASE_HOOK" '{"tool_input":{"command":"git commit --amend"}}'
assert_exit 2 "release: 直接 git commit --amend 硬拦"
assert_stderr_has "commit-task-for-review.sh -m" "release: git commit --amend 文案仍含首次 -m 指引"
assert_stderr_has "commit-task-for-review.sh --amend" "release: git commit --amend 文案含 --amend 指引"

run_hook "$RELEASE_HOOK" '{"tool_input":{"command":"git merge --no-ff feature/x"}}'
assert_exit 2 "release: 直接 git merge --no-ff 硬拦"
assert_stderr_has "merge-task-to-local-master.sh --user-authorized" "release: 直接 git merge --no-ff 指向标准入口"

run_hook "$RELEASE_HOOK" '{"tool_input":{"command":"git merge feature/x"}}'
assert_exit 2 "release: 直接 git merge 工单分支硬拦"
assert_stderr_has "merge-task-to-local-master.sh --user-authorized" "release: 直接 git merge 工单分支指向标准入口"

# git merge origin/master 分支感知（ADR-0010）：
# 任务分支上拦截并指向 rebase 同步入口；master 集成区放行。
setup_git_stub
export FAKE_BRANCH=feature/ik0test

run_hook "$RELEASE_HOOK" '{"tool_input":{"command":"git merge origin/master"}}'
assert_exit 2 "release: 任务分支上 merge origin/master 硬拦"
assert_stderr_has "sync-task-from-origin.sh sync" "release: 任务分支同步 merge 指向 rebase 同步入口"

# git pull（无 --ff-only / --rebase）在任务分支上与 merge origin/master 等价拦截
run_hook "$RELEASE_HOOK" '{"tool_input":{"command":"git pull"}}'
assert_exit 2 "release: 任务分支上 git pull 硬拦"
assert_stderr_has "sync-task-from-origin.sh sync" "release: 任务分支 pull 指向 rebase 同步入口"

run_hook "$RELEASE_HOOK" '{"tool_input":{"command":"git pull origin master"}}'
assert_exit 2 "release: 任务分支上 git pull origin master 硬拦"
assert_stderr_has "sync-task-from-origin.sh sync" "release: 任务分支 pull origin master 指向 rebase 同步入口"

# --ff-only / --rebase 变体在任务分支上放行（安全同步模式）
run_hook "$RELEASE_HOOK" '{"tool_input":{"command":"git pull --ff-only"}}'
assert_exit 0 "release: 任务分支上 git pull --ff-only 放行"
assert_stdout_empty "release: git pull --ff-only 无交互输出"

run_hook "$RELEASE_HOOK" '{"tool_input":{"command":"git pull --rebase"}}'
assert_exit 0 "release: 任务分支上 git pull --rebase 放行"
assert_stdout_empty "release: git pull --rebase 无交互输出"

run_hook "$RELEASE_HOOK" '{"tool_input":{"command":"git pull -r"}}'
assert_exit 0 "release: 任务分支上 git pull -r 放行"
assert_stdout_empty "release: git pull -r 无交互输出"

# --ff-only=<ref> 变体正确识别为安全 ff-only
run_hook "$RELEASE_HOOK" '{"tool_input":{"command":"git merge --ff-only=refs/heads/master origin/master"}}'
assert_exit 0 "release: git merge --ff-only=<ref> 正确放行"
assert_stdout_empty "release: git merge --ff-only=<ref> 无交互输出"

run_hook "$RELEASE_HOOK" '{"tool_input":{"command":"git pull --ff-only=refs/heads/master"}}'
assert_exit 0 "release: git pull --ff-only=<ref> 正确放行"
assert_stdout_empty "release: git pull --ff-only=<ref> 无交互输出"

# master 分支上 merge/pull origin/master 不拦截（用户本地集成区，ADR-0010）
export FAKE_BRANCH=master

run_hook "$RELEASE_HOOK" '{"tool_input":{"command":"git merge origin/master"}}'
assert_exit 0 "release: master 分支上 merge origin/master 放行"
assert_stdout_empty "release: master 上 merge origin/master 无交互输出"

run_hook "$RELEASE_HOOK" '{"tool_input":{"command":"git pull"}}'
assert_exit 0 "release: master 分支上 git pull 放行"
assert_stdout_empty "release: master 上 git pull 无交互输出"

run_hook "$RELEASE_HOOK" '{"tool_input":{"command":"git pull origin master"}}'
assert_exit 0 "release: master 分支上 git pull origin master 放行"
assert_stdout_empty "release: master 上 git pull origin master 无交互输出"

teardown_git_stub
unset FAKE_BRANCH

run_hook "$RELEASE_HOOK" '{"tool_input":{"command":"scripts/sync-task-from-origin.sh sync --json"}}'
assert_exit 0 "release: 标准同步入口静默放行"
assert_stdout_empty "release: 标准同步入口无 Hook 输出"

run_hook "$RELEASE_HOOK" '{"tool_input":{"command":"git merge --ff-only origin/master"}}'
assert_exit 0 "release: git merge --ff-only 同步放行"
assert_stdout_not_has '"permissionDecision":"ask"' "release: git merge --ff-only 不触发确认"

# 标准本地验收入口：worktree commit 本地可逆，出现即放行（不校验 --user-authorized）。
run_hook "$RELEASE_HOOK" '{"tool_input":{"command":"scripts/commit-task-for-review.sh -m \"feat: task slice\""}}'
assert_exit 0 "release: commit-task-for-review 出现即放行（无需 --user-authorized）"
assert_stdout_empty "release: commit-task-for-review 无交互输出"

# hook 只认入口名、不校验 --user-authorized：命令仍含该参数时 hook 层照常放行（参数合法性由脚本自身处理）。
run_hook "$RELEASE_HOOK" '{"tool_input":{"command":"scripts/commit-task-for-review.sh --user-authorized -m \"feat: task slice\""}}'
assert_exit 0 "release: commit-task-for-review 含残留 --user-authorized 时 hook 层放行"

run_hook "$RELEASE_HOOK" '{"tool_input":{"command":"scripts/merge-task-to-local-master.sh feature/x"}}'
assert_exit 2 "release: merge-task-to-local-master 缺参数被拦截"
assert_stderr_has "--user-authorized" "release: merge-task-to-local-master 缺参数提示授权参数"

run_hook "$RELEASE_HOOK" '{"tool_input":{"command":"scripts/merge-task-to-local-master.sh --user-authorized feature/x"}}'
assert_exit 0 "release: merge-task-to-local-master 授权入口放行"
assert_stdout_empty "release: merge-task-to-local-master 无交互输出"

# bash 包裹新发布审查包入口带授权和模式 → 仍应无交互放行
run_hook "$RELEASE_HOOK" '{"tool_input":{"command":"bash scripts/publish-review-package.sh --user-authorized --create-pr"}}'
assert_exit 0 "release: bash publish-review-package create 授权入口放行"
assert_stdout_empty "release: bash publish-review-package create 无交互输出"

# bash -lc 包裹标准入口仍应识别
run_hook "$RELEASE_HOOK" '{"tool_input":{"command":"bash -lc \"scripts/publish-review-package.sh --user-authorized --update-pr 65 --pr-snapshot /tmp/pr-65.json\""}}'
assert_exit 0 "release: bash -lc publish-review-package update 授权入口放行"
assert_stdout_empty "release: bash -lc publish-review-package update 无交互输出"

# 标准入口不能掩盖同一复合命令中的裸 Git 操作。
run_hook "$RELEASE_HOOK" '{"tool_input":{"command":"scripts/commit-task-for-review.sh -m \"feat: x\" && git commit -m \"bypass\""}}'
assert_exit 2 "release: 标准 commit 入口后裸 commit 仍硬拦"
run_hook "$RELEASE_HOOK" '{"tool_input":{"command":"scripts/commit-task-for-review.sh -m \"feat: x\" && scripts/merge-task-to-local-master.sh feature/x"}}'
assert_exit 2 "release: commit-task 入口后接无授权 merge-task 仍硬拦"
assert_stderr_has "--user-authorized" "release: 复合命令提示 merge 授权"
run_hook "$RELEASE_HOOK" '{"tool_input":{"command":"scripts/merge-task-to-local-master.sh --user-authorized feature/x && git merge --no-ff feature/y"}}'
assert_exit 2 "release: 标准 merge 入口后裸 merge 仍硬拦"
run_hook "$RELEASE_HOOK" '{"tool_input":{"command":"scripts/publish-review-package.sh --user-authorized --create-pr && git commit -m \"bypass\""}}'
assert_exit 2 "release: 标准 publish 入口后裸 commit 仍硬拦"

# 内联和仓库 Git alias 不能绕过 push / commit / merge 分类。
run_hook "$RELEASE_HOOK" '{"tool_input":{"command":"git -c alias.ship=push ship origin feature/x"}}'
assert_exit 2 "release: inline alias push 硬拦"
run_hook "$RELEASE_HOOK" '{"tool_input":{"command":"git -c alias.save=commit save -m \"bypass\""}}'
assert_exit 2 "release: inline alias commit 硬拦"
run_hook "$RELEASE_HOOK" '{"tool_input":{"command":"git -c alias.integrate=\"merge --no-ff\" integrate feature/x"}}'
assert_exit 2 "release: inline alias merge 硬拦"

ALIAS_TEST_ROOT="$(mktemp -d)"
"$REAL_GIT" -C "$ALIAS_TEST_ROOT" init -q
"$REAL_GIT" -C "$ALIAS_TEST_ROOT" config alias.ship push
"$REAL_GIT" -C "$ALIAS_TEST_ROOT" config alias.save commit
"$REAL_GIT" -C "$ALIAS_TEST_ROOT" config alias.integrate 'merge --no-ff'
"$REAL_GIT" -C "$ALIAS_TEST_ROOT" config alias.option-ship '-c foo.bar=baz push'
"$REAL_GIT" -C "$ALIAS_TEST_ROOT" config alias.option-save '-c foo.bar=baz commit'
"$REAL_GIT" -C "$ALIAS_TEST_ROOT" config alias.option-integrate '-c foo.bar=baz merge --no-ff'
run_hook "$RELEASE_HOOK" "$(printf '{\"tool_input\":{\"command\":\"git -C %s ship origin feature/x\"}}' "$ALIAS_TEST_ROOT")"
assert_exit 2 "release: configured alias push 硬拦"
run_hook "$RELEASE_HOOK" "$(printf '{\"tool_input\":{\"command\":\"git -C %s save -m bypass\"}}' "$ALIAS_TEST_ROOT")"
assert_exit 2 "release: configured alias commit 硬拦"
run_hook "$RELEASE_HOOK" "$(printf '{\"tool_input\":{\"command\":\"git -C %s integrate feature/x\"}}' "$ALIAS_TEST_ROOT")"
assert_exit 2 "release: configured alias merge 硬拦"
run_hook "$RELEASE_HOOK" "$(printf '{\"tool_input\":{\"command\":\"git -C %s option-ship origin feature/x\"}}' "$ALIAS_TEST_ROOT")"
assert_exit 2 "release: configured alias with global option push 硬拦"
run_hook "$RELEASE_HOOK" "$(printf '{\"tool_input\":{\"command\":\"git -C %s option-save -m bypass\"}}' "$ALIAS_TEST_ROOT")"
assert_exit 2 "release: configured alias with global option commit 硬拦"
run_hook "$RELEASE_HOOK" "$(printf '{\"tool_input\":{\"command\":\"git -C %s option-integrate feature/x\"}}' "$ALIAS_TEST_ROOT")"
assert_exit 2 "release: configured alias with global option merge 硬拦"
rm -rf "$ALIAS_TEST_ROOT"

# 项目清理脚本依靠自身校验，不在发布 Hook 中弹确认
run_hook "$RELEASE_HOOK" '{"tool_input":{"command":"scripts/cleanup-task-worktree.sh"}}'
assert_exit 0 "release: cleanup-task-worktree 放行"

# 主 checkout 验证 worktree 脚本硬停的复合命令不应误触发发布确认
run_hook "$RELEASE_HOOK" '{"tool_input":{"command":"cd /Users/jj.reno/Blue-Whale\n# 主 checkout 跑 worktree 脚本应硬停\nscripts/cleanup-task-worktree.sh 2>&1; echo \"exit=$?\"\necho \"---\"\nscripts/publish-task-branch.sh 2>&1; echo \"exit=$?\"\necho \"---\"\nscripts/ensure-graphify-worktree.sh 2>&1; echo \"exit=$?\""}}'
assert_exit 0 "release: 复合验证命令放行"

# 只验证清理/graphify 脚本时不应误触发发布确认
run_hook "$RELEASE_HOOK" '{"tool_input":{"command":"cd /Users/jj.reno/Blue-Whale\nscripts/cleanup-task-worktree.sh 2>&1; echo \"exit=$?\"\necho \"---\"\nscripts/ensure-graphify-worktree.sh 2>&1; echo \"exit=$?\""}}'
assert_exit 0 "release: 非发布验证复合命令放行"

# 创建合法普通 PR（缺 draft）→ Pre 只校验形态放行，不消费标记（消费延后到 Post，见 ADR-0011）
setup_publish_test_repo
write_publish_marker "feature/x"
run_hook "$RELEASE_HOOK" '{"tool_name":"mcp__gitee-ent__create_enterprise_repo_pull","tool_use_id":"tu_create_pr_allow","session_id":"s_ik10dr_release","tool_input":{"source_branch":"feature/x","target_branch":"master","title":"SECRET_PR_TITLE"}}'
assert_exit 0 "release: 普通 PR 放行不二次确认"
assert_stdout_not_has '"permissionDecision":"ask"' "release: 普通 PR 不二次确认"
assert_file_exists "$(publish_marker_path feature/x)" "release: 普通 PR Pre 阶段不消费标记（延后到 Post）"
PUBLISH_AUDIT_LOG="$(audit_log_path "$PUBLISH_TEST_ROOT" "$RELEASE_HOOK")"
assert_audit_record_field "$PUBLISH_AUDIT_LOG" tu_create_pr_allow operation create-pr "audit-all: create PR 记录操作类别"
assert_audit_record_field "$PUBLISH_AUDIT_LOG" tu_create_pr_allow exit_code 0 "audit-all: create PR 放行记录"
assert_file_not_has_text "$PUBLISH_AUDIT_LOG" SECRET_PR_TITLE "audit-all: create PR 不记录 MCP 参数"

# 创建显式非 draft PR → Pre 只校验形态放行，不消费标记（消费延后到 Post，见 ADR-0011）
write_publish_marker "feature/x"
run_hook "$RELEASE_HOOK" '{"tool_name":"mcp__gitee-ent__create_enterprise_repo_pull","tool_input":{"source_branch":"feature/x","target_branch":"master","draft":"false","title":"test"}}'
assert_exit 0 "release: 非 draft PR 放行不二次确认"
assert_stdout_not_has '"permissionDecision":"ask"' "release: 非 draft PR 不二次确认"
assert_file_exists "$(publish_marker_path feature/x)" "release: 非 draft PR Pre 阶段不消费标记（延后到 Post）"

# 直接创建合法形态普通 PR 但缺少发布审查包标记 → 阻断
remove_publish_marker feature/x
run_hook "$RELEASE_HOOK" '{"tool_name":"mcp__gitee-ent__create_enterprise_repo_pull","tool_input":{"source_branch":"feature/x","target_branch":"master","title":"test"}}'
assert_exit 2 "release: 普通 PR 缺发布标记拦截"
assert_stderr_has "--create-pr" "release: 普通 PR 缺发布标记提示 create 模式"

# G+ 标记按分支隔离：写 feature/other 标记，PR 用 source=feature/x 只找 feature%x 文件，
# 找不到 → 落到「缺标记」阻断（等效防伪造消费授权，失败模式从「不匹配」变为「缺标记」，
# 因标记路径本身含分支 slug，结构性消除了「找到别人标记」的可能）。
write_publish_marker "feature/other"
run_hook "$RELEASE_HOOK" '{"tool_name":"mcp__gitee-ent__create_enterprise_repo_pull","tool_input":{"source_branch":"feature/x","target_branch":"master","title":"test"}}'
assert_exit 2 "release: 跨分支 PR 找不到对应标记拦截"
assert_stderr_has "--create-pr" "release: 跨分支 PR 缺标记提示 create 模式"
remove_publish_marker feature/other

# 过期发布标记 → 阻断并消费标记
write_publish_marker "feature/x" "master" "1"
run_hook "$RELEASE_HOOK" '{"tool_name":"mcp__gitee-ent__create_enterprise_repo_pull","tool_input":{"source_branch":"feature/x","target_branch":"master","title":"test"}}'
assert_exit 2 "release: 普通 PR 发布标记过期"
assert_stderr_has "已过期" "release: 普通 PR 发布标记过期提示"
assert_file_missing "$(publish_marker_path feature/x)" "release: 普通 PR 过期标记被清理"

# 创建 draft PR → 阻断
write_publish_marker "feature/x"
run_hook "$RELEASE_HOOK" '{"tool_name":"mcp__gitee-ent__create_enterprise_repo_pull","tool_input":{"source_branch":"feature/x","target_branch":"master","draft":"true","title":"test"}}'
assert_exit 2 "release: draft PR 拦截"
assert_stderr_has "不使用 draft PR" "release: draft PR 提示普通 PR"
remove_publish_marker feature/x

# 创建 PR 缺 target_branch → 阻断
run_hook "$RELEASE_HOOK" '{"tool_name":"mcp__gitee-ent__create_enterprise_repo_pull","tool_input":{"source_branch":"feature/x","title":"test"}}'
assert_exit 2 "release: 缺 target_branch PR 拦截"

# 创建 PR 缺 source_branch → 阻断
run_hook "$RELEASE_HOOK" '{"tool_name":"mcp__gitee-ent__create_enterprise_repo_pull","tool_input":{"target_branch":"master","title":"test"}}'
assert_exit 2 "release: 缺 source_branch PR 拦截"

# 创建非 master 目标 PR → 阻断
run_hook "$RELEASE_HOOK" '{"tool_name":"mcp__gitee-ent__create_enterprise_repo_pull","tool_input":{"source_branch":"feature/x","target_branch":"develop","draft":"false","title":"test"}}'
assert_exit 2 "release: 非 master 目标 PR 拦截"

# 合并 PR → 必须持有绑定企业/仓库/PR 的一次性凭证。
# squash/rebase 方法检查已并入 confirm-release-action.sh（在凭证校验前），
# 消除多 hook 执行顺序不确定导致的纠正信号误导。
setup_action_test_repo
remove_all_action_markers

# squash 方法错误优先于凭证校验报出（无论是否有凭证）。
write_action_marker merge-pr 987654321 876543219 765432198
run_hook "$RELEASE_HOOK" '{"tool_use_id":"tu_merge_squash","session_id":"s_ik10dr_release","tool_name":"mcp__gitee-ent__merge_enterprise_pull","tool_input":{"enterprise_id":987654321,"project_id":"876543219","pull_request_id":765432198,"merge_method":"squash"}}'
assert_exit 2 "release: merge PR squash 方法优先拦截（即使有凭证）"
assert_stderr_has "squash" "release: merge PR squash 提示含 squash"
ACTION_AUDIT_LOG="$(audit_log_path "$ACTION_TEST_ROOT" "$RELEASE_HOOK")"
assert_audit_record_field "$ACTION_AUDIT_LOG" tu_merge_squash operation merge-pr "audit-all: squash 由权威 release Gate 记录"
assert_audit_record_field "$ACTION_AUDIT_LOG" tu_merge_squash exit_code 2 "audit-all: squash 阻断记录"
assert_file_not_has_text "$ACTION_AUDIT_LOG" 987654321 "audit-all: merge PR 不记录 enterprise_id"
assert_file_not_has_text "$ACTION_AUDIT_LOG" 876543219 "audit-all: merge PR 不记录 project_id"
assert_file_not_has_text "$ACTION_AUDIT_LOG" 765432198 "audit-all: merge PR 不记录 pull_request_id"

run_hook "$RELEASE_HOOK" '{"tool_use_id":"tu_merge_rebase","session_id":"s_ik10dr_release","tool_name":"mcp__gitee-ent__merge_enterprise_pull","tool_input":{"enterprise_id":987654321,"project_id":"876543219","pull_request_id":765432198,"merge_method":"rebase"}}'
assert_exit 2 "release: merge PR rebase 方法优先拦截（即使有凭证）"
assert_stderr_has "rebase" "release: merge PR rebase 提示含 rebase"
assert_audit_record_field "$ACTION_AUDIT_LOG" tu_merge_rebase operation merge-pr "audit-all: rebase 由权威 release Gate 记录"

# 消费 squash 测试写入的凭证，避免污染后续用例。
remove_all_action_markers

run_hook "$RELEASE_HOOK" '{"tool_use_id":"merge-12-missing","tool_name":"mcp__gitee-ent__merge_enterprise_pull","tool_input":{"enterprise_id":16660949,"project_id":"48854568","pull_request_id":12,"merge_method":"merge"}}'
assert_exit 2 "release: merge PR 缺凭证拦截"
assert_stderr_has "manage-agent-authorization.sh grant" "release: merge PR 缺凭证提示自动授权入口"

write_action_marker merge-pr 16660949 48854568 12
run_hook "$RELEASE_HOOK" '{"tool_use_id":"merge-12-a","tool_name":"mcp__gitee-ent__merge_enterprise_pull","tool_input":{"enterprise_id":16660949,"project_id":"48854568","pull_request_id":12,"merge_method":"merge"}}'
assert_exit 0 "release: merge PR 有效凭证首次 claim 放行"
assert_stdout_empty "release: merge PR 无交互输出"
assert_audit_record_field "$ACTION_AUDIT_LOG" merge-12-a operation merge-pr "audit-all: merge PR 记录操作类别"
assert_audit_record_field "$ACTION_AUDIT_LOG" merge-12-a exit_code 0 "audit-all: merge PR 放行记录"
assert_file_exists "$(authorization_marker_path merge-pr 16660949 48854568 12)" "release: merge PR Pre 不消费凭证"
assert_file_exists "$(authorization_claim_path merge-pr 16660949 48854568 12)" "release: merge PR Pre 原子占用凭证"

run_hook "$RELEASE_HOOK" '{"tool_use_id":"merge-12-b","tool_name":"mcp__gitee-ent__merge_enterprise_pull","tool_input":{"enterprise_id":16660949,"project_id":"48854568","pull_request_id":12,"merge_method":"merge"}}'
assert_exit 2 "release: merge PR 同凭证并发 claim 拦截"
assert_stderr_has "已被另一个工具调用占用" "release: merge PR 并发占用提示"

run_hook "$RELEASE_HOOK" '{"hook_event_name":"PostToolUse","tool_use_id":"merge-12-a","tool_name":"mcp__gitee-ent__merge_enterprise_pull","tool_input":{"enterprise_id":16660949,"project_id":"48854568","pull_request_id":12,"merge_method":"merge"},"tool_response":{"isError":true}}'
assert_exit 0 "release: merge PR 失败 Post 放行"
assert_file_exists "$(authorization_marker_path merge-pr 16660949 48854568 12)" "release: merge PR 失败 Post 保留凭证"
assert_file_missing "$(authorization_claim_path merge-pr 16660949 48854568 12)" "release: merge PR 失败 Post 释放占用"

run_hook "$RELEASE_HOOK" '{"tool_use_id":"merge-12-b","tool_name":"mcp__gitee-ent__merge_enterprise_pull","tool_input":{"enterprise_id":16660949,"project_id":"48854568","pull_request_id":12,"merge_method":"merge"}}'
assert_exit 0 "release: merge PR 失败释放后可重试"
run_hook "$RELEASE_HOOK" '{"hook_event_name":"PostToolUse","tool_use_id":"merge-12-b","tool_name":"mcp__gitee-ent__merge_enterprise_pull","tool_input":{"enterprise_id":16660949,"project_id":"48854568","pull_request_id":12,"merge_method":"merge"},"tool_response":{"isError":false}}'
assert_exit 0 "release: merge PR 成功 Post 放行"
assert_file_missing "$(authorization_marker_path merge-pr 16660949 48854568 12)" "release: merge PR 成功 Post 消费凭证"
assert_file_missing "$(authorization_claim_path merge-pr 16660949 48854568 12)" "release: merge PR 成功 Post 清理占用"

write_action_marker merge-pr 16660949 48854568 17
run_hook "$RELEASE_HOOK" '{"tool_name":"mcp__gitee-ent__merge_enterprise_pull","tool_input":{"enterprise_id":16660949,"project_id":"48854568","pull_request_id":17,"merge_method":"merge"}}'
assert_exit 2 "release: merge PR 缺 tool_use_id 拦截"
assert_stderr_has "tool_use_id" "release: merge PR 缺 tool_use_id 提示"

# Kimi CLI 载荷：关联 id 字段为 tool_call_id（无 tool_use_id），Gate 经回退等价 claim/consume。
write_action_marker merge-pr 16660949 48854568 21
run_hook "$RELEASE_HOOK" '{"tool_call_id":"kimi-merge-21","session_id":"kimi-s1","tool_name":"mcp__gitee-ent__merge_enterprise_pull","tool_input":{"enterprise_id":16660949,"project_id":"48854568","pull_request_id":21,"merge_method":"merge"}}'
assert_exit 0 "release: Kimi merge PR tool_call_id claim 放行"
assert_audit_record_field "$ACTION_AUDIT_LOG" kimi-merge-21 operation merge-pr "audit-all: Kimi merge PR 以 tool_call_id 记录审计"
assert_file_exists "$(authorization_claim_path merge-pr 16660949 48854568 21)" "release: Kimi merge PR Pre 原子占用凭证"
run_hook "$RELEASE_HOOK" '{"hook_event_name":"PostToolUse","tool_call_id":"kimi-merge-21","session_id":"kimi-s1","tool_name":"mcp__gitee-ent__merge_enterprise_pull","tool_input":{"enterprise_id":16660949,"project_id":"48854568","pull_request_id":21,"merge_method":"merge"},"tool_output":"{\"state\":\"merged\"}"}'
assert_exit 0 "release: Kimi merge PR 成功 Post 放行"
assert_file_missing "$(authorization_marker_path merge-pr 16660949 48854568 21)" "release: Kimi merge PR 成功 Post 消费凭证"
assert_file_missing "$(authorization_claim_path merge-pr 16660949 48854568 21)" "release: Kimi merge PR 成功 Post 清理占用"

write_action_marker merge-pr 16660949 48854568 13 1
run_hook "$RELEASE_HOOK" '{"tool_use_id":"merge-13","tool_name":"mcp__gitee-ent__merge_enterprise_pull","tool_input":{"enterprise_id":16660949,"project_id":"48854568","pull_request_id":13,"merge_method":"merge"}}'
assert_exit 2 "release: merge PR 过期凭证拦截"
assert_stderr_has "已过期" "release: merge PR 过期凭证提示"
assert_file_missing "$(authorization_marker_path merge-pr 16660949 48854568 13)" "release: merge PR 过期凭证清理"

write_action_marker merge-pr 16660949 48854568 14
run_hook "$RELEASE_HOOK" '{"tool_use_id":"merge-15","tool_name":"mcp__gitee-ent__merge_enterprise_pull","tool_input":{"enterprise_id":16660949,"project_id":"48854568","pull_request_id":15,"merge_method":"merge"}}'
assert_exit 2 "release: merge PR 对象错配拦截"
assert_file_exists "$(authorization_marker_path merge-pr 16660949 48854568 14)" "release: merge PR 对象错配不消费其他凭证"

malformed_marker="$(authorization_marker_path merge-pr 16660949 48854568 16)"
mkdir -p "$(dirname "$malformed_marker")"
printf 'version=1\naction=merge-pr\n' >"$malformed_marker"
run_hook "$RELEASE_HOOK" '{"tool_use_id":"merge-16","tool_name":"mcp__gitee-ent__merge_enterprise_pull","tool_input":{"enterprise_id":16660949,"project_id":"48854568","pull_request_id":16,"merge_method":"merge"}}'
assert_exit 2 "release: merge PR 非法凭证拦截"
assert_stderr_has "凭证无效" "release: merge PR 非法凭证提示"
assert_file_missing "$malformed_marker" "release: merge PR 非法凭证清理"

# 创建 release → 使用绑定 tag 的一次性凭证，失败保留、成功消费。
write_action_marker create-release 16660949 48854568 v1.0.0
run_hook "$RELEASE_HOOK" '{"tool_use_id":"release-v1","tool_name":"mcp__gitee-ent__create_enterprise_repo_release","tool_input":{"enterprise_id":16660949,"project_id":"48854568","release_tag_version":"v1.0.0","release_title":"v1.0.0","release_description":"test"}}'
assert_exit 0 "release: create release 有效凭证放行"
assert_stdout_empty "release: create release 无交互输出"
assert_audit_record_field "$ACTION_AUDIT_LOG" release-v1 operation create-release "audit-all: create release 记录操作类别"
assert_audit_record_field "$ACTION_AUDIT_LOG" release-v1 exit_code 0 "audit-all: create release 放行记录"
assert_file_exists "$(authorization_marker_path create-release 16660949 48854568 v1.0.0)" "release: create release Pre 不消费凭证"

run_hook "$RELEASE_HOOK" '{"hook_event_name":"PostToolUse","tool_use_id":"release-v1","tool_name":"mcp__gitee-ent__create_enterprise_repo_release","tool_input":{"enterprise_id":16660949,"project_id":"48854568","release_tag_version":"v1.0.0","release_title":"v1.0.0","release_description":"test"},"tool_response":{"isError":false}}'
assert_exit 0 "release: create release 成功 Post 放行"
assert_file_missing "$(authorization_marker_path create-release 16660949 48854568 v1.0.0)" "release: create release 成功 Post 消费凭证"

write_action_marker create-release 16660949 48854568 v1.1.0
run_hook "$RELEASE_HOOK" '{"tool_use_id":"release-v1-ambiguous","tool_name":"mcp__gitee-ent__create_enterprise_repo_release","tool_input":{"enterprise_id":16660949,"project_id":"48854568","release_tag_version":"v1.1.0","release_title":"v1.1.0","release_description":"test"}}'
assert_exit 0 "release: create release 歧义 Post 前 claim 放行"
run_hook "$RELEASE_HOOK" '{"hook_event_name":"PostToolUse","tool_use_id":"release-v1-ambiguous","tool_name":"mcp__gitee-ent__create_enterprise_repo_release","tool_input":{"enterprise_id":16660949,"project_id":"48854568","release_tag_version":"v1.1.0"},"tool_response":{"isError":"false"}}'
assert_exit 0 "release: create release 畸形 Post 放行"
assert_file_exists "$(authorization_marker_path create-release 16660949 48854568 v1.1.0)" "release: create release 畸形 Post 保留凭证"
assert_file_missing "$(authorization_claim_path create-release 16660949 48854568 v1.1.0)" "release: create release 畸形 Post 释放占用"

# AI 管理入口：grant/revoke/revoke --all 全自动管理，不需要人类处理文件。
run_authorization grant --user-authorized merge-pr --enterprise-id 16660949 --project-id 48854568 --pull-request-id 21
assert_exit 0 "authorization: grant merge-pr 成功"
assert_file_exists "$(authorization_marker_path merge-pr 16660949 48854568 21)" "authorization: grant 写入 merge-pr 凭证"
assert_file_mode_600 "$(authorization_marker_path merge-pr 16660949 48854568 21)" "authorization: grant 凭证权限 0600"

run_authorization revoke merge-pr --enterprise-id 16660949 --project-id 48854568 --pull-request-id 21
assert_exit 0 "authorization: revoke merge-pr 成功"
assert_file_missing "$(authorization_marker_path merge-pr 16660949 48854568 21)" "authorization: revoke 删除 merge-pr 凭证"

run_authorization grant --user-authorized create-release --enterprise-id 16660949 --project-id 48854568 --release-tag-version v2.0.0
assert_exit 0 "authorization: grant create-release 成功"
run_authorization revoke --all
assert_exit 0 "authorization: revoke --all 成功"
assert_file_missing "$(authorization_marker_path create-release 16660949 48854568 v2.0.0)" "authorization: revoke --all 删除全部凭证"

run_authorization grant merge-pr --enterprise-id 16660949 --project-id 48854568 --pull-request-id 22
assert_exit 2 "authorization: grant 缺 user-authorized 拦截"
assert_stderr_has "--user-authorized" "authorization: grant 缺授权提示"

run_authorization_helper grant "$ACTION_TEST_ROOT" merge-pr 16660949 48854568 23
assert_exit 2 "authorization: helper direct grant 缺授权声明拦截"
assert_stderr_has "--user-authorized" "authorization: helper direct grant 缺授权提示"
teardown_action_test_repo

# 回归（G+）：标记按 branch 隔离，不同分支标记互不覆盖。
# 防本次缺陷复发——publish 在 worktree 写、hook 在主仓读，common dir 对称使其命中；
# 且并行多分支发布时，一条分支的 PR 消费（Post 撕票）不应误删另一分支标记。
write_publish_marker "feature/aaa"
write_publish_marker "feature/bbb"
assert_file_exists "$(publish_marker_path feature/aaa)" "release: G+ 并行 aaa 标记独立存在"
assert_file_exists "$(publish_marker_path feature/bbb)" "release: G+ 并行 bbb 标记独立存在"
run_hook "$RELEASE_HOOK" '{"tool_name":"mcp__gitee-ent__create_enterprise_repo_pull","tool_input":{"source_branch":"feature/aaa","target_branch":"master","title":"test"}}'
assert_exit 0 "release: G+ 并行场景 aaa PR 放行"
assert_file_exists "$(publish_marker_path feature/aaa)" "release: G+ aaa Pre 阶段不消费（延后到 Post）"
assert_file_exists "$(publish_marker_path feature/bbb)" "release: G+ bbb 标记不受 aaa 影响"
remove_publish_marker "feature/aaa"
remove_publish_marker "feature/bbb"

# G+ Post 隔离回归：Post 消费 aaa 不应误删 bbb（恢复跨分支隔离守卫意图）。
write_publish_marker "feature/aaa"
write_publish_marker "feature/bbb"
run_hook "$RELEASE_HOOK" '{"hook_event_name":"PostToolUse","tool_name":"mcp__gitee-ent__create_enterprise_repo_pull","tool_input":{"source_branch":"feature/aaa","target_branch":"master","title":"test"},"tool_response":{"isError":false}}'
assert_exit 0 "release: G+ Post aaa 放行"
assert_file_missing "$(publish_marker_path feature/aaa)" "release: G+ Post aaa 被消费"
assert_file_exists "$(publish_marker_path feature/bbb)" "release: G+ Post aaa 消费不误删 bbb"
remove_publish_marker "feature/aaa"
remove_publish_marker "feature/bbb"

# PostToolUse 消费标记：只有 tool_response.isError=false 明确证明 PR 创建成功才撕票（ADR-0011）。
write_publish_marker "feature/x"
assert_file_exists "$(publish_marker_path feature/x)" "release: Post 消费前标记存在"
post_audit_lines_before=$(grep -c '' "$PUBLISH_AUDIT_LOG" 2>/dev/null || echo 0)
run_hook "$RELEASE_HOOK" '{"hook_event_name":"PostToolUse","tool_name":"mcp__gitee-ent__create_enterprise_repo_pull","tool_input":{"source_branch":"feature/x","target_branch":"master","title":"test"},"tool_response":{"isError":false}}'
assert_exit 0 "release: Post create PR 放行（不阻断已执行工具）"
assert_file_missing "$(publish_marker_path feature/x)" "release: Post 创建成功消费标记"
post_audit_lines_after=$(grep -c '' "$PUBLISH_AUDIT_LOG" 2>/dev/null || echo 0)
if [ "$post_audit_lines_before" = "$post_audit_lines_after" ]; then
  PASS=$((PASS + 1))
else
  FAIL=$((FAIL + 1))
  FAILURES+=("[audit-all: PostToolUse 不审计] before=${post_audit_lines_before} after=${post_audit_lines_after}")
fi

# Post 响应缺失或类型畸形时不能证明成功，保留发布标记等待明确结果或 TTL。
write_publish_marker "feature/x"
run_hook "$RELEASE_HOOK" '{"hook_event_name":"PostToolUse","tool_name":"mcp__gitee-ent__create_enterprise_repo_pull","tool_input":{"source_branch":"feature/x","target_branch":"master"},"tool_response":{"isError":"false"}}'
assert_exit 0 "release: Post 畸形 isError 放行不阻断"
assert_file_exists "$(publish_marker_path feature/x)" "release: Post 畸形 isError 保留标记"
remove_publish_marker feature/x

# Kimi CLI Post：载荷无 tool_response，成功输出字段为 tool_output（kimi PostToolUse 仅成功时触发）→ 撕票。
write_publish_marker "feature/kimi-post"
run_hook "$RELEASE_HOOK" '{"hook_event_name":"PostToolUse","session_id":"kimi-s1","cwd":"/tmp","tool_name":"mcp__gitee-ent__create_enterprise_repo_pull","tool_input":{"source_branch":"feature/kimi-post","target_branch":"master","title":"test"},"tool_call_id":"tool_kimi_post_1","tool_output":"{\"iid\":1}"}'
assert_exit 0 "release: Kimi Post create PR 放行"
assert_file_missing "$(publish_marker_path feature/kimi-post)" "release: Kimi Post tool_output 视为成功并消费标记"
remove_publish_marker "feature/kimi-post"

# 无 tool_response 且无 tool_output 的 Post 载荷（畸形/未知平台）保守保留标记。
write_publish_marker "feature/x"
run_hook "$RELEASE_HOOK" '{"hook_event_name":"PostToolUse","tool_name":"mcp__gitee-ent__create_enterprise_repo_pull","tool_input":{"source_branch":"feature/x","target_branch":"master","title":"test"}}'
assert_exit 0 "release: Post 无成功证明字段放行不阻断"
assert_file_exists "$(publish_marker_path feature/x)" "release: Post 无成功证明字段保留标记"
remove_publish_marker feature/x

# Post 缺 source_branch 不 consume（guard）：撕票需 source_branch 算路径，缺失则不动标记。
write_publish_marker "feature/x"
run_hook "$RELEASE_HOOK" '{"hook_event_name":"PostToolUse","tool_name":"mcp__gitee-ent__create_enterprise_repo_pull","tool_input":{"target_branch":"master","title":"test"},"tool_response":{"isError":false}}'
assert_exit 0 "release: Post 缺 source_branch 放行不阻断"
assert_file_exists "$(publish_marker_path feature/x)" "release: Post 缺 source_branch 不消费标记"
remove_publish_marker feature/x
teardown_publish_test_repo

# Slice 2 — block-issue-without-repo（核心：project_id 类型漂移回归基线）
# MCP schema: project_id 为 number。本组同时喂 number 与 string 两种形态，
# 防止正则退回 string-only 时 number 用例漏检（PR #11 / IJZ5WA 复现）。
ISSUE_HOOK=block-issue-without-repo.sh

# 字段全缺 → 拦
run_hook "$ISSUE_HOOK" '{"tool_input":{}}'
assert_exit 2 "issue: project_id 缺失拦截"

# 根 issue 只传 project_id（缺 program_id）→ 拦
run_hook "$ISSUE_HOOK" '{"tool_input":{"project_id":48854568}}'
assert_exit 2 "issue: 根 issue 缺 program_id 拦截"
assert_stderr_has "program_id" "issue: 根 issue 缺 program_id 提示"

# project_id number 0（Gitee 无关联哨兵）→ 拦
run_hook "$ISSUE_HOOK" '{"tool_input":{"project_id":0}}'
assert_exit 2 "issue: project_id=number 0 拦截"

# project_id string "0" → 拦
run_hook "$ISSUE_HOOK" '{"tool_input":{"project_id":"0"}}'
assert_exit 2 "issue: project_id=string \"0\" 拦截"

# project_id + program_id 都是 number 合法值 + description → 放行（schema 原生形态，回归基线核心）
run_hook "$ISSUE_HOOK" '{"tool_input":{"project_id":48854568,"program_id":883843,"description":"正文"}}'
assert_exit 0 "issue: project_id/program_id=number 放行"

# project_id + program_id 都是 string 合法值 + description → 放行
run_hook "$ISSUE_HOOK" '{"tool_input":{"project_id":"48854568","program_id":"883843","description":"正文"}}'
assert_exit 0 "issue: project_id/program_id=string 放行"

# create 缺 description → 拦（错名参数静默忽略防空工单，IK5THP）
run_hook "$ISSUE_HOOK" '{"tool_name":"mcp__gitee-ent__create_enterprise_issue","tool_input":{"project_id":48854568,"program_id":883843,"title":"t"}}'
assert_exit 2 "issue: create 缺 description 拦截"
assert_stderr_has "description 缺失或为空" "issue: create 缺 description 提示"

# create 误传 body（正确参数名是 description）→ 拦
run_hook "$ISSUE_HOOK" '{"tool_name":"mcp__gitee-ent__create_enterprise_issue","tool_input":{"project_id":48854568,"program_id":883843,"title":"t","body":"x"}}'
assert_exit 2 "issue: create 误传 body 拦截"

# 根 issue program_id=number 0（project_id 合法）→ 拦
run_hook "$ISSUE_HOOK" '{"tool_input":{"project_id":48854568,"program_id":0}}'
assert_exit 2 "issue: 根 issue program_id=number 0 拦截"

# 根 issue program_id=string "0"（project_id 合法）→ 拦
run_hook "$ISSUE_HOOK" '{"tool_input":{"project_id":48854568,"program_id":"0"}}'
assert_exit 2 "issue: 根 issue program_id=string \"0\" 拦截"

# 子 issue 只传 parent_id、不传 project_id → 拦
run_hook "$ISSUE_HOOK" '{"tool_name":"mcp__gitee-ent__create_enterprise_issue","tool_input":{"parent_id":33553306}}'
assert_exit 2 "issue: 子 issue 缺 project_id 拦截"
assert_stderr_has "子 issue 缺少 project_id" "issue: 子 issue 缺 project_id 提示"

# 子 issue 有 parent_id/project_id，但缺 program_id → 拦
run_hook "$ISSUE_HOOK" '{"tool_name":"mcp__gitee-ent__create_enterprise_issue","tool_input":{"parent_id":33553306,"project_id":48854568}}'
assert_exit 2 "issue: 子 issue 缺 program_id 拦截"
assert_stderr_has "子 issue 缺少 program_id" "issue: 子 issue 缺 program_id 提示"

# 子 issue 同时继承 parent_id/project_id/program_id → 放行
run_hook "$ISSUE_HOOK" '{"tool_name":"mcp__gitee-ent__create_enterprise_issue","tool_input":{"parent_id":33553306,"project_id":48854568,"program_id":883843,"description":"子项正文"}}'
assert_exit 0 "issue: 子 issue 继承父项归属放行"

# update 只改状态/标签，不要求重复传 project_id → 放行
run_hook "$ISSUE_HOOK" '{"tool_name":"mcp__gitee-ent__update_enterprise_issue","tool_use_id":"tu_issue_update_allow","tool_input":{"issue_id":"IJZ5WA","issue_state_id":123,"label_ids":"342812299"}}'
assert_exit 0 "issue: 普通 update 放行"
assert_audit_record_field "$(audit_log_path "$HOOK_AUDIT_TEST_ROOT" "$ISSUE_HOOK")" tu_issue_update_allow operation issue-update "audit-all: update issue 记录操作类别"

# update 显式 project_id=0 → 拦
run_hook "$ISSUE_HOOK" '{"tool_name":"mcp__gitee-ent__update_enterprise_issue","tool_input":{"issue_id":"IJZ5WA","project_id":0}}'
assert_exit 2 "issue: update project_id=0 拦截"

# update 显式 program_id=0 → 拦（对称 project_id=0）
run_hook "$ISSUE_HOOK" '{"tool_name":"mcp__gitee-ent__update_enterprise_issue","tool_input":{"issue_id":"IJZ5WA","program_id":0}}'
assert_exit 2 "issue: update program_id=0 拦截"

# update 子 issue 时只传 parent_id、不补 project_id/program_id → 拦
run_hook "$ISSUE_HOOK" '{"tool_name":"mcp__gitee-ent__update_enterprise_issue","tool_input":{"issue_id":"IJZ74J","parent_id":33553306}}'
assert_exit 2 "issue: update 子 issue 缺归属拦截"

# update 子 issue 补齐 parent_id/project_id/program_id → 放行
run_hook "$ISSUE_HOOK" '{"tool_name":"mcp__gitee-ent__update_enterprise_issue","tool_input":{"issue_id":"IJZ74J","parent_id":33553306,"project_id":48854568,"program_id":883843}}'
assert_exit 0 "issue: update 子 issue 继承父项归属放行"

# ── 回归基线：string-only 正则在 number 形态下漏检 ──
# 直接验证「如果正则退回 string-only，number 输入会漏」这一事实，
# 不依赖 hook 当前实现。失败即说明回归防护失效（夹具本身坏了）。
STRING_ONLY_MATCH="$(printf '%s' '{"tool_input":{"project_id":48854568}}' \
  | grep -oE '"project_id"[[:space:]]*:[[:space:]]*"[^"]*"' | head -n1)"
if [ -z "$STRING_ONLY_MATCH" ]; then
  PASS=$((PASS + 1))
else
  FAIL=$((FAIL + 1))
  FAILURES+=("[issue 回归基线] string-only 正则竟匹配到 number 形态=\"${STRING_ONLY_MATCH}\"（应漏才对，说明基线失效）")
fi
TOTAL_BASELINE=1

# Slice 3 — block-push-to-master（git stub 隔离当前分支推断）
PUSH_HOOK=block-push-to-master.sh

setup_git_stub

# 显式 push origin master → 拦
export FAKE_BRANCH=feature/无关分支
run_hook "$PUSH_HOOK" '{"tool_input":{"command":"git push origin master"}}'
assert_exit 2 "push: 显式 master 拦截"
assert_stderr_has "master" "push: master 提示含 master"

# git 全局选项形式 push origin master → 拦
run_hook "$PUSH_HOOK" '{"tool_input":{"command":"git -C ../blue-whale-worktrees/task push origin master"}}'
assert_exit 2 "push: git -C master 拦截"
assert_stderr_has "master" "push: git -C master 提示含 master"

# JSON 转义引号不能截断 command 后绕过 master push 检测
run_hook "$PUSH_HOOK" '{"tool_input":{"command":"echo \"ready\"; git push origin master"}}'
assert_exit 2 "push: 转义引号后 master 拦截"
assert_stderr_has "master" "push: 转义引号后 master 提示含 master"

# 显式 push origin main → 拦
run_hook "$PUSH_HOOK" '{"tool_input":{"command":"git push origin main"}}'
assert_exit 2 "push: 显式 main 拦截"

# FAKE_BRANCH=master + 隐式 push（无 refspec）→ 拦（命中 fake git）
export FAKE_BRANCH=master
run_hook "$PUSH_HOOK" '{"tool_input":{"command":"git push"}}'
assert_exit 2 "push: 当前分支 master 隐式 push 拦截"
assert_stderr_has "master" "push: 隐式 master 提示含 master"

# FAKE_BRANCH=feature/x + 隐式 push → 放行（工单分支）
export FAKE_BRANCH=feature/x
run_hook "$PUSH_HOOK" '{"tool_input":{"command":"git push"}}'
assert_exit 0 "push: 当前分支 feature/x 隐式 push 放行"

# 显式 push origin feature/x → 放行
run_hook "$PUSH_HOOK" '{"tool_input":{"command":"git push origin feature/x"}}'
assert_exit 0 "push: 显式 feature/x 放行"

teardown_git_stub
unset FAKE_BRANCH

# Slice 4 — block-dangerous-git（复用 git stub 隔离当前分支）
DANGER_HOOK=block-dangerous-git.sh

setup_git_stub
export FAKE_BRANCH=feature/x

# 裸 --force → 无条件拦
run_hook "$DANGER_HOOK" '{"tool_input":{"command":"git push --force origin feature/x"}}'
assert_exit 2 "danger: 裸 --force 拦截"
assert_stderr_has "--force" "danger: --force 提示含 force"

# --force-with-lease 到工单分支 → 放行
run_hook "$DANGER_HOOK" '{"tool_input":{"command":"git push --force-with-lease origin feature/x"}}'
assert_exit 0 "danger: --force-with-lease feature/x 放行"

# git 全局选项形式的裸 --force → 拦
run_hook "$DANGER_HOOK" '{"tool_input":{"command":"git -C ../blue-whale-worktrees/task push --force origin feature/x"}}'
assert_exit 2 "danger: git -C 裸 --force 拦截"
assert_stderr_has "--force" "danger: git -C --force 提示含 force"

# git reset --hard → 拦
run_hook "$DANGER_HOOK" '{"tool_input":{"command":"git reset --hard HEAD~1"}}'
assert_exit 2 "danger: reset --hard 拦截"

# git clean -fd → 拦
run_hook "$DANGER_HOOK" '{"tool_input":{"command":"git clean -fd"}}'
assert_exit 2 "danger: clean -fd 拦截"

# git branch -D → 拦
run_hook "$DANGER_HOOK" '{"tool_input":{"command":"git branch -D feature/x"}}'
assert_exit 2 "danger: branch -D 拦截"

# git checkout . → 拦
run_hook "$DANGER_HOOK" '{"tool_input":{"command":"git checkout ."}}'
assert_exit 2 "danger: checkout . 拦截"

# git restore . → 拦
run_hook "$DANGER_HOOK" '{"tool_input":{"command":"git restore ."}}'
assert_exit 2 "danger: restore . 拦截"

teardown_git_stub
unset FAKE_BRANCH

# Slice 4.2 — 其余运行时阻断型 PreToolUse Gate 审计闭环（IK10DR）
# 用统一临时 Git 仓库观测 stdin JSON → exit/stdout/stderr + 持久记录，避免污染真实 common dir。
DANGER_AUDIT_LOG="$(audit_log_path "$HOOK_AUDIT_TEST_ROOT" "$DANGER_HOOK")"
run_hook "$DANGER_HOOK" '{"tool_name":"Bash","tool_use_id":"tu_danger_block","session_id":"s_ik10dr","tool_input":{"command":"git reset --hard SECRET_DANGER_COMMAND"}}'
assert_exit 2 "audit-all: dangerous 阻断 exit 2 不变"
assert_stdout_empty "audit-all: dangerous 阻断 stdout 为空"
assert_stderr_has "危险 git 操作" "audit-all: dangerous 阻断信息保留"
assert_audit_record_field "$DANGER_AUDIT_LOG" tu_danger_block operation git-reset-hard "audit-all: dangerous 阻断操作类别"
assert_audit_record_field "$DANGER_AUDIT_LOG" tu_danger_block exit_code 2 "audit-all: dangerous 阻断记录"
run_hook "$DANGER_HOOK" '{"tool_name":"Bash","tool_use_id":"tu_danger_allow","session_id":"s_ik10dr","tool_input":{"command":"git status --short SECRET_DANGER_ALLOW"}}'
assert_exit 0 "audit-all: dangerous 放行 exit 0 不变"
assert_stdout_empty "audit-all: dangerous 放行 stdout 为空"
assert_audit_record_field "$DANGER_AUDIT_LOG" tu_danger_allow operation bash-other "audit-all: dangerous 放行操作类别"
assert_audit_record_field "$DANGER_AUDIT_LOG" tu_danger_allow exit_code 0 "audit-all: dangerous 放行记录"
assert_file_not_has_text "$DANGER_AUDIT_LOG" SECRET_DANGER_COMMAND "audit-all: dangerous 不记录完整命令"
assert_file_not_has_text "$DANGER_AUDIT_LOG" SECRET_DANGER_ALLOW "audit-all: dangerous 不记录放行命令"

PUSH_AUDIT_LOG="$(audit_log_path "$HOOK_AUDIT_TEST_ROOT" "$PUSH_HOOK")"
run_hook "$PUSH_HOOK" '{"tool_name":"Bash","tool_use_id":"tu_push_block","session_id":"s_ik10dr","tool_input":{"command":"git push origin master SECRET_PUSH_COMMAND"}}'
assert_exit 2 "audit-all: protected push 阻断 exit 2 不变"
assert_stdout_empty "audit-all: protected push 阻断 stdout 为空"
assert_stderr_has "直推 master" "audit-all: protected push 阻断信息保留"
assert_audit_record_field "$PUSH_AUDIT_LOG" tu_push_block operation git-push-protected "audit-all: protected push 阻断操作类别"
assert_audit_record_field "$PUSH_AUDIT_LOG" tu_push_block exit_code 2 "audit-all: protected push 阻断记录"
run_hook "$PUSH_HOOK" '{"tool_name":"Bash","tool_use_id":"tu_push_allow","session_id":"s_ik10dr","tool_input":{"command":"git push origin feature/x SECRET_PUSH_ALLOW"}}'
assert_exit 0 "audit-all: work branch push 放行 exit 0 不变"
assert_stdout_empty "audit-all: work branch push 放行 stdout 为空"
assert_audit_record_field "$PUSH_AUDIT_LOG" tu_push_allow operation git-push-unprotected "audit-all: work branch push 放行操作类别"
assert_audit_record_field "$PUSH_AUDIT_LOG" tu_push_allow exit_code 0 "audit-all: work branch push 放行记录"
assert_file_not_has_text "$PUSH_AUDIT_LOG" SECRET_PUSH_COMMAND "audit-all: protected push 不记录完整命令"
assert_file_not_has_text "$PUSH_AUDIT_LOG" SECRET_PUSH_ALLOW "audit-all: work branch push 不记录完整命令"

RELEASE_AUDIT_LOG="$(audit_log_path "$HOOK_AUDIT_TEST_ROOT" "$RELEASE_HOOK")"
run_hook "$RELEASE_HOOK" '{"tool_name":"Bash","tool_use_id":"tu_release_block","session_id":"s_ik10dr","tool_input":{"command":"git push origin feature/x SECRET_RELEASE_COMMAND","token":"SECRET_RELEASE_TOKEN","file_path":"SECRET_RELEASE_FILE","tool_name":"SECRET_NESTED_TOOL"}}'
assert_exit 2 "audit-all: release 阻断 exit 2 不变"
assert_stdout_empty "audit-all: release 阻断 stdout 为空"
assert_stderr_has "直接 git push" "audit-all: release 阻断信息保留"
assert_audit_record_field "$RELEASE_AUDIT_LOG" tu_release_block operation git-push "audit-all: release 阻断操作类别"
assert_audit_record_field "$RELEASE_AUDIT_LOG" tu_release_block exit_code 2 "audit-all: release 阻断记录"
run_hook "$RELEASE_HOOK" '{"tool_name":"Bash","tool_use_id":"tu_release_allow","session_id":"s_ik10dr","tool_input":{"command":"git status --short SECRET_RELEASE_ALLOW"}}'
assert_exit 0 "audit-all: release 放行 exit 0 不变"
assert_stdout_empty "audit-all: release 放行 stdout 为空"
assert_audit_record_field "$RELEASE_AUDIT_LOG" tu_release_allow operation bash-other "audit-all: release 放行操作类别"
assert_audit_record_field "$RELEASE_AUDIT_LOG" tu_release_allow exit_code 0 "audit-all: release 放行记录"
assert_file_not_has_text "$RELEASE_AUDIT_LOG" SECRET_RELEASE_COMMAND "audit-all: release 不记录完整命令"
assert_file_not_has_text "$RELEASE_AUDIT_LOG" SECRET_RELEASE_ALLOW "audit-all: release 不记录放行命令"
assert_file_not_has_text "$RELEASE_AUDIT_LOG" SECRET_RELEASE_TOKEN "audit-all: release 不记录凭证"
assert_file_not_has_text "$RELEASE_AUDIT_LOG" SECRET_RELEASE_FILE "audit-all: release 不记录嵌套 file_path"
assert_file_not_has_text "$RELEASE_AUDIT_LOG" SECRET_NESTED_TOOL "audit-all: release 不记录嵌套 tool_name"

ISSUE_AUDIT_LOG="$(audit_log_path "$HOOK_AUDIT_TEST_ROOT" "$ISSUE_HOOK")"
run_hook "$ISSUE_HOOK" '{"tool_name":"mcp__gitee-ent__create_enterprise_issue","tool_use_id":"tu_issue_block","session_id":"s_ik10dr","tool_input":{"title":"SECRET_ISSUE_TITLE","token":"SECRET_ISSUE_TOKEN","file_path":"SECRET_ISSUE_FILE","tool_name":"SECRET_ISSUE_NESTED_TOOL"}}'
assert_exit 2 "audit-all: issue 阻断 exit 2 不变"
assert_stdout_empty "audit-all: issue 阻断 stdout 为空"
assert_stderr_has "project_id" "audit-all: issue 阻断信息保留"
assert_audit_record_field "$ISSUE_AUDIT_LOG" tu_issue_block operation issue-create "audit-all: issue 阻断操作类别"
assert_audit_record_field "$ISSUE_AUDIT_LOG" tu_issue_block exit_code 2 "audit-all: issue 阻断记录"
run_hook "$ISSUE_HOOK" '{"tool_name":"mcp__gitee-ent__create_enterprise_issue","tool_use_id":"tu_issue_allow","session_id":"s_ik10dr","tool_input":{"project_id":987654321,"program_id":123456789,"title":"SECRET_ISSUE_ALLOW","description":"SECRET_ISSUE_ALLOW_DESC"}}'
assert_exit 0 "audit-all: issue 放行 exit 0 不变"
assert_stdout_empty "audit-all: issue 放行 stdout 为空"
assert_audit_record_field "$ISSUE_AUDIT_LOG" tu_issue_allow operation issue-create "audit-all: issue 放行操作类别"
assert_audit_record_field "$ISSUE_AUDIT_LOG" tu_issue_allow exit_code 0 "audit-all: issue 放行记录"
assert_file_not_has_text "$ISSUE_AUDIT_LOG" SECRET_ISSUE_TITLE "audit-all: issue 不记录标题"
assert_file_not_has_text "$ISSUE_AUDIT_LOG" SECRET_ISSUE_TOKEN "audit-all: issue 不记录 token"
assert_file_not_has_text "$ISSUE_AUDIT_LOG" SECRET_ISSUE_FILE "audit-all: issue 不记录嵌套 file_path"
assert_file_not_has_text "$ISSUE_AUDIT_LOG" SECRET_ISSUE_NESTED_TOOL "audit-all: issue 不记录嵌套 tool_name"
assert_file_not_has_text "$ISSUE_AUDIT_LOG" SECRET_ISSUE_ALLOW "audit-all: issue 不记录放行参数"
assert_file_not_has_text "$ISSUE_AUDIT_LOG" 987654321 "audit-all: issue 不记录 project_id"
assert_file_not_has_text "$ISSUE_AUDIT_LOG" 123456789 "audit-all: issue 不记录 program_id"

for audited_gate in "$DANGER_HOOK" "$PUSH_HOOK" "$RELEASE_HOOK" "$ISSUE_HOOK"; do
  assert_audit_not_tracked "$HOOK_AUDIT_TEST_ROOT" "$audited_gate" "audit-all: ${audited_gate} 审计不进入 Git 视图"
done

# 每个新增接入 Gate 的审计设施失败都保持原决策，只增加共享契约允许的降级提示。
AUDIT_DEGRADE_REPO="$(mktemp -d)"
"$REAL_GIT" -C "$AUDIT_DEGRADE_REPO" init -q
touch "$AUDIT_DEGRADE_REPO/.git/hook-audit"
AUDIT_DEGRADE_SAVED="$CLAUDE_PROJECT_DIR"
export CLAUDE_PROJECT_DIR="$AUDIT_DEGRADE_REPO"

run_hook "$DANGER_HOOK" '{"tool_name":"Bash","tool_input":{"command":"git reset --hard HEAD~1"}}'
assert_exit 2 "audit-all: dangerous 审计失败仍阻断"
assert_stdout_empty "audit-all: dangerous 审计失败 stdout 为空"
assert_stderr_has "危险 git 操作" "audit-all: dangerous 审计失败保留原信息"
assert_stderr_has "hook-audit: degraded" "audit-all: dangerous 审计失败提示降级"
run_hook "$PUSH_HOOK" '{"tool_name":"Bash","tool_input":{"command":"git push origin master"}}'
assert_exit 2 "audit-all: protected push 审计失败仍阻断"
assert_stdout_empty "audit-all: protected push 审计失败 stdout 为空"
assert_stderr_has "直推 master" "audit-all: protected push 审计失败保留原信息"
assert_stderr_has "hook-audit: degraded" "audit-all: protected push 审计失败提示降级"
run_hook "$RELEASE_HOOK" '{"tool_name":"Bash","tool_input":{"command":"git push origin feature/x"}}'
assert_exit 2 "audit-all: release 审计失败仍阻断"
assert_stdout_empty "audit-all: release 审计失败 stdout 为空"
assert_stderr_has "直接 git push" "audit-all: release 审计失败保留原信息"
assert_stderr_has "hook-audit: degraded" "audit-all: release 审计失败提示降级"
run_hook "$ISSUE_HOOK" '{"tool_name":"mcp__gitee-ent__create_enterprise_issue","tool_input":{}}'
assert_exit 2 "audit-all: issue 审计失败仍阻断"
assert_stdout_empty "audit-all: issue 审计失败 stdout 为空"
assert_stderr_has "project_id" "audit-all: issue 审计失败保留原信息"
assert_stderr_has "hook-audit: degraded" "audit-all: issue 审计失败提示降级"

export CLAUDE_PROJECT_DIR="$AUDIT_DEGRADE_SAVED"
rm -rf "$AUDIT_DEGRADE_REPO"
unset DANGER_AUDIT_LOG PUSH_AUDIT_LOG RELEASE_AUDIT_LOG ISSUE_AUDIT_LOG
unset AUDIT_DEGRADE_REPO AUDIT_DEGRADE_SAVED audited_gate

# Slice 4.5 — block-master-edit（按 file_path 所属工作树判分支 + 仓库边界）
MASTER_EDIT_HOOK=block-master-edit.sh

setup_git_stub
# 两个工作树共存：主 checkout（master）+ worktree（工单分支）
export FAKE_BRANCH_MAP=$'/tmp/repo\tmaster\n/tmp/worktree\tfeature/ik096s'
export FAKE_TOPLEVEL_MAP=$'/tmp/repo\t/tmp/repo\n/tmp/worktree\t/tmp/worktree'

# 主 checkout master，Edit 主 checkout 内文件 → 拦
run_hook "$MASTER_EDIT_HOOK" '{"tool_name":"Edit","tool_input":{"file_path":"/tmp/repo/src/a.py"}}'
assert_exit 2 "master-edit: 主 checkout master 文件拦截"

# Kimi CLI 形状：tool_input 路径参数为 path（无 file_path）→ 同判拦截/放行
run_hook "$MASTER_EDIT_HOOK" '{"tool_name":"Write","tool_call_id":"tool_k1","tool_input":{"path":"/tmp/repo/src/a.py"}}'
assert_exit 2 "master-edit: Kimi path 形状 master 文件拦截"
run_hook "$MASTER_EDIT_HOOK" '{"tool_name":"Write","tool_call_id":"tool_k2","tool_input":{"path":"/tmp/worktree/src/b.py"}}'
assert_exit 0 "master-edit: Kimi path 形状工单分支文件放行"

# 主 checkout session（cwd=master），Edit worktree 工单分支文件 → 放行
# 核心：按 file_path 所属工作树解析得工单分支，不靠「worktree 路径不在主 toplevel 前缀内」的布局假设
run_hook "$MASTER_EDIT_HOOK" '{"tool_name":"Edit","tool_input":{"file_path":"/tmp/worktree/src/b.py"}}'
assert_exit 0 "master-edit: cwd=master 编辑 worktree 工单分支文件放行"

# 主 checkout session，Edit 仓库外 dotfile → 放行（-C 目录未命中 MAP → 非工作树）
run_hook "$MASTER_EDIT_HOOK" '{"tool_name":"Edit","tool_input":{"file_path":"/Users/x/.codex/config.toml"}}'
assert_exit 0 "master-edit: 仓库外 dotfile 放行"

# 非 Edit 工具 → 放行（无论 file_path 在哪个工作树）
run_hook "$MASTER_EDIT_HOOK" '{"tool_name":"Read","tool_input":{"file_path":"/tmp/repo/src/a.py"}}'
assert_exit 0 "master-edit: 非 Edit 工具放行"

# detached HEAD worktree（分支解析为空）→ 放行
export FAKE_BRANCH_MAP=$'/tmp/detached\t'
export FAKE_TOPLEVEL_MAP=$'/tmp/detached\t/tmp/detached'
run_hook "$MASTER_EDIT_HOOK" '{"tool_name":"Edit","tool_input":{"file_path":"/tmp/detached/src/c.py"}}'
assert_exit 0 "master-edit: detached HEAD worktree 放行"

teardown_git_stub
unset FAKE_BRANCH FAKE_GIT_TOPLEVEL FAKE_BRANCH_MAP FAKE_TOPLEVEL_MAP

# Slice 4.6 — block-master-edit 真实 git 端到端
# stub 的 git -C 用纯前缀匹配，不模拟「目录不存在→失败」与「git -C . 退化 cwd」，
# 故 fail-open 回归（#1）与 file_path 缺失 fallback（#2）只能用真实 git 覆盖。
REAL_REPO="$(mktemp -d)"
git -C "$REAL_REPO" init -q
git -C "$REAL_REPO" symbolic-ref HEAD refs/heads/master  # 强制 master（防 git 默认 main）

# #1: master 仓库内 Write 全新子目录文件（父目录链不存在）→ 向上遍历应解析到 master → 拦
#     修复前：git -C <不存在目录> 失败 → BRANCH/TOPLEVEL 空 → 误判仓库外放行（fail-open）
run_hook "$MASTER_EDIT_HOOK" "$(printf '{"tool_name":"Write","tool_input":{"file_path":"%s/brand/new/sub/file.ts"}}' "$REAL_REPO")"
assert_exit 2 "master-edit(real): master 仓库内不存在子目录 Write 拦截（#1 fail-open 回归）"

# #2: file_path 缺失 → dirname("")="." → git -C "." 退化 cwd（=临时 master 仓库）→ 拦
#     锁定 fallback，防未来重构静默破坏
( cd "$REAL_REPO" && printf '%s' '{"tool_name":"Edit","tool_input":{}}' | bash "${HOOK_DIR}/${MASTER_EDIT_HOOK}" ) 2>/dev/null
RUN_EXIT=$?
assert_exit 2 "master-edit(real): file_path 缺失 cwd=master 退化拦截（#2 fallback 锁定）"

rm -rf "$REAL_REPO"

# 非 master 分支 + 不存在子目录 Write → 向上遍历解析得非 master → 放行
# 锁定 walk 不过度阻塞（与 #1 对称的 must-not-regress，stub 屏蔽 walk 故走真实 git）
FEATURE_REPO="$(mktemp -d)"
git -C "$FEATURE_REPO" init -q
git -C "$FEATURE_REPO" symbolic-ref HEAD refs/heads/feature/x
run_hook "$MASTER_EDIT_HOOK" "$(printf '{"tool_name":"Write","tool_input":{"file_path":"%s/brand/new/sub/f.ts"}}' "$FEATURE_REPO")"
assert_exit 0 "master-edit(real): 非 master 仓库不存在子目录 Write 放行（walk 不过度阻塞）"
rm -rf "$FEATURE_REPO"
unset REAL_REPO FEATURE_REPO

# Slice 4.6.5 — block-master-edit 本地个人配置白名单
# 只放行根 CLAUDE.local.md + .codex/config.toml，且必须先被 Git 明确忽略；
# 其他 ignored 文件与未忽略的同名配置仍按 master 写入硬拦。
LOCALCFG_REPO="$(mktemp -d)"
git -C "$LOCALCFG_REPO" init -q
git -C "$LOCALCFG_REPO" symbolic-ref HEAD refs/heads/master
mkdir -p "$LOCALCFG_REPO/.codex"
printf '/CLAUDE.local.md\n/.codex/config.toml\n/.env\n' > "$LOCALCFG_REPO/.gitignore"
SAVED_CLAUDE_PROJECT_DIR_LOCALCFG="${CLAUDE_PROJECT_DIR:-}"
export CLAUDE_PROJECT_DIR="$LOCALCFG_REPO"

run_hook "$MASTER_EDIT_HOOK" '{"tool_name":"Write","tool_input":{"file_path":"'"$LOCALCFG_REPO"'/CLAUDE.local.md"}}'
assert_exit 0 "local-config: 已忽略根 CLAUDE.local.md 放行"
run_hook "$MASTER_EDIT_HOOK" '{"tool_name":"Edit","tool_input":{"file_path":"'"$LOCALCFG_REPO"'/.codex/config.toml"}}'
assert_exit 0 "local-config: 已忽略 .codex/config.toml 放行"

run_hook "$MASTER_EDIT_HOOK" '{"tool_name":"Edit","tool_input":{"file_path":"'"$LOCALCFG_REPO"'/.env"}}'
assert_exit 2 "local-config: 其他已忽略文件仍拦"
printf '/CLAUDE.local.md\n/.env\n' > "$LOCALCFG_REPO/.gitignore"
run_hook "$MASTER_EDIT_HOOK" '{"tool_name":"Edit","tool_input":{"file_path":"'"$LOCALCFG_REPO"'/.codex/config.toml"}}'
assert_exit 2 "local-config: 未忽略 .codex/config.toml 仍拦"

export CLAUDE_PROJECT_DIR="$SAVED_CLAUDE_PROJECT_DIR_LOCALCFG"
rm -rf "$LOCALCFG_REPO"
unset LOCALCFG_REPO SAVED_CLAUDE_PROJECT_DIR_LOCALCFG

# Slice 4.6.6 — block-master-edit 文档白名单（ADR-0025）
# 真实 master 仓库：根 CONTEXT.md + docs/**/*.md 放行；代码 / .claude 规则源 / 契约仍拦。
DOCALLO_REPO="$(mktemp -d)"
git -C "$DOCALLO_REPO" init -q
git -C "$DOCALLO_REPO" symbolic-ref HEAD refs/heads/master
mkdir -p "$DOCALLO_REPO/docs/adr" "$DOCALLO_REPO/docs/specs" "$DOCALLO_REPO/.claude/rules" "$DOCALLO_REPO/src"
SAVED_CLAUDE_PROJECT_DIR_DOCALLO="${CLAUDE_PROJECT_DIR:-}"
export CLAUDE_PROJECT_DIR="$DOCALLO_REPO"

# 放行：根 CONTEXT.md + 审计 reason=allowed-doc-allowlist
run_hook "$MASTER_EDIT_HOOK" '{"tool_name":"Edit","tool_use_id":"tu_ctx","session_id":"s_doc","tool_input":{"file_path":"'"$DOCALLO_REPO"'/CONTEXT.md"}}'
assert_exit 0 "doc-allowlist: master Edit 根 CONTEXT.md 放行（ADR-0025）"
DOCALLO_LOG="$(audit_log_path "$DOCALLO_REPO" "$MASTER_EDIT_HOOK")"
assert_audit_has_field "$DOCALLO_LOG" reason allowed-doc-allowlist "doc-allowlist: CONTEXT.md 放行审计 reason=allowed-doc-allowlist"

# 放行：docs 任意层级 .md（含子目录、全新文件 Write）
run_hook "$MASTER_EDIT_HOOK" '{"tool_name":"Edit","tool_input":{"file_path":"'"$DOCALLO_REPO"'/docs/adr/0001.md"}}'
assert_exit 0 "doc-allowlist: master Edit docs/adr/0001.md 放行"
run_hook "$MASTER_EDIT_HOOK" '{"tool_name":"Write","tool_input":{"file_path":"'"$DOCALLO_REPO"'/docs/new.md"}}'
assert_exit 0 "doc-allowlist: master Write docs/new.md 放行"

# 仍拦：代码 / 规则源（CLAUDE.md + .claude/rules）/ 契约（docs/**/*.json 非 .md 散文）
run_hook "$MASTER_EDIT_HOOK" '{"tool_name":"Edit","tool_input":{"file_path":"'"$DOCALLO_REPO"'/src/a.py"}}'
assert_exit 2 "doc-allowlist: master Edit 代码 src/a.py 仍拦"
run_hook "$MASTER_EDIT_HOOK" '{"tool_name":"Edit","tool_input":{"file_path":"'"$DOCALLO_REPO"'/CLAUDE.md"}}'
assert_exit 2 "doc-allowlist: master Edit 根 CLAUDE.md 规则源仍拦"
run_hook "$MASTER_EDIT_HOOK" '{"tool_name":"Edit","tool_input":{"file_path":"'"$DOCALLO_REPO"'/.claude/rules/issue-tracker.md"}}'
assert_exit 2 "doc-allowlist: master Edit .claude/rules 规则源仍拦"
run_hook "$MASTER_EDIT_HOOK" '{"tool_name":"Edit","tool_input":{"file_path":"'"$DOCALLO_REPO"'/docs/specs/schema.json"}}'
assert_exit 2 "doc-allowlist: master Edit docs/specs/*.json 契约仍拦（非 .md 散文）"

# 路径穿越回归：docs/../src/a.py 经 pwd -P 折叠 .. 后落 src/a.py → 非白名单 → 拦
run_hook "$MASTER_EDIT_HOOK" '{"tool_name":"Edit","tool_input":{"file_path":"'"$DOCALLO_REPO"'/docs/../src/a.py"}}'
assert_exit 2 "doc-allowlist: 路径穿越 docs/../src/a.py 经 pwd -P 折叠后仍拦"

export CLAUDE_PROJECT_DIR="$SAVED_CLAUDE_PROJECT_DIR_DOCALLO"
rm -rf "$DOCALLO_REPO"
unset DOCALLO_REPO SAVED_CLAUDE_PROJECT_DIR_DOCALLO DOCALLO_LOG

# Slice 4.6.7 — commit-spec-on-master.sh（ADR-0025 落盘入口）
# 真实 master 仓库端到端：doc-only 通过 + docs: 前缀；git mv 代码进 docs/ 被 --no-renames 捕获拒。
commit_spec_setup() {
  local repo="$1"
  git -C "$repo" init -q
  git -C "$repo" symbolic-ref HEAD refs/heads/master
  git -C "$repo" config user.email t@t
  git -C "$repo" config user.name t
  mkdir -p "$repo/docs" "$repo/src"
  printf 'old\n' > "$repo/src/a.py"
  git -C "$repo" add -A && git -C "$repo" commit -q -m "feat: baseline"
}

# 用例1：doc-only CONTEXT.md → 落盘 master + docs: 前缀
SPEC1="$(mktemp -d)"; commit_spec_setup "$SPEC1"
printf 'ctx\n' > "$SPEC1/CONTEXT.md"
( cd "$SPEC1" && bash "$REPO_ROOT/scripts/commit-spec-on-master.sh" -m "补领域语言" ) >/dev/null 2>&1
RUN_EXIT=$?
assert_exit 0 "commit-spec: doc-only CONTEXT.md 落盘 master（exit 0）"
git -C "$SPEC1" log -1 --format=%s | grep -q '^docs: 补领域语言' && PASS=$((PASS + 1)) || { FAIL=$((FAIL + 1)); FAILURES+=("[commit-spec: docs: 前缀自动添加]"); }
rm -rf "$SPEC1"

# 用例2：git mv 代码进 docs/（rename）→ --no-renames 捕获旧路径 src/a.py → 拒绝（ADR-0025 威胁边界回归）
SPEC2="$(mktemp -d)"; commit_spec_setup "$SPEC2"
git -C "$SPEC2" mv src/a.py docs/malicious.md 2>/dev/null || { FAIL=$((FAIL + 1)); FAILURES+=("[commit-spec: 预置 git mv 失败]"); }
( cd "$SPEC2" && bash "$REPO_ROOT/scripts/commit-spec-on-master.sh" -m "改名" ) >/dev/null 2>&1
RUN_EXIT=$?
assert_exit 1 "commit-spec: git mv 代码进 docs/ rename 被拒（--no-renames 捕获旧路径 src/a.py）"
rm -rf "$SPEC2"
unset -f commit_spec_setup 2>/dev/null || true
unset SPEC1 SPEC2

# Slice 4.7 — block-master-edit 审计闭环（IK10CW）
# 用真实 git 仓库（stub git 不支持 rev-parse --git-common-dir，审计 helper 依赖它）。
# 覆盖 AC：阻断记录、放行记录、字段安全、stdout 契约、降级、轮转、并发、不被跟踪。
AUDIT_HOOK=block-master-edit.sh
AUDIT_REPO="$(mktemp -d)"
git -C "$AUDIT_REPO" init -q
git -C "$AUDIT_REPO" symbolic-ref HEAD refs/heads/master
git -C "$AUDIT_REPO" config user.email t@t
git -C "$AUDIT_REPO" config user.name t
SAVED_CLAUDE_PROJECT_DIR_AUDIT="${CLAUDE_PROJECT_DIR:-}"
export CLAUDE_PROJECT_DIR="$AUDIT_REPO"

# AC1: master 阻断 → exit 2 + stdout 空 + 审计记录含 tool/branch/exit_code/reason
run_hook "$AUDIT_HOOK" '{"tool_name":"Edit","tool_use_id":"tu_blk","session_id":"s_audit","tool_input":{"file_path":"'"$AUDIT_REPO"'/src/a.py"}}'
assert_exit 2 "audit: master Edit 阻断（exit 2 不变）"
assert_stdout_empty "audit: master 阻断 stdout 保持为空"
assert_stderr_has "禁止在 master" "audit: master 阻断保留既有原因"
AUDIT_LOG="$(audit_log_path "$AUDIT_REPO" "$AUDIT_HOOK")"
assert_audit_has_field "$AUDIT_LOG" tool Edit "audit: 阻断记录含 tool=Edit"
assert_audit_has_field "$AUDIT_LOG" branch master "audit: 阻断记录含 branch=master"
assert_audit_has_field "$AUDIT_LOG" operation file-write "audit: master Gate 使用共享 operation 字段"
assert_audit_has_field "$AUDIT_LOG" exit_code 2 "audit: 阻断记录含 exit_code=2"
assert_audit_has_field "$AUDIT_LOG" reason blocked-master "audit: 阻断记录含 reason=blocked-master"
assert_audit_has_field "$AUDIT_LOG" tool_use_id tu_blk "audit: 阻断记录含 tool_use_id"
assert_audit_has_field "$AUDIT_LOG" session_id s_audit "audit: 阻断记录含 session_id"

# AC2: 非 master 放行 → exit 0 + stdout 空 + 放行记录
git -C "$AUDIT_REPO" worktree add -b feature/audit-wt "$AUDIT_REPO-wt" 2>/dev/null
run_hook "$AUDIT_HOOK" '{"tool_name":"Write","tool_use_id":"tu_allow","session_id":"s_audit","tool_input":{"file_path":"'"$AUDIT_REPO-wt"'/src/b.py"}}'
assert_exit 0 "audit: 非 master Write 放行（exit 0 不变）"
assert_stdout_empty "audit: 放行 stdout 保持为空"
assert_audit_has_field "$AUDIT_LOG" tool Write "audit: 放行记录含 tool=Write"
assert_audit_has_field "$AUDIT_LOG" branch feature/audit-wt "audit: 放行记录含 branch=feature/audit-wt"
assert_audit_has_field "$AUDIT_LOG" exit_code 0 "audit: 放行记录含 exit_code=0"
assert_audit_has_field "$AUDIT_LOG" reason allowed-non-master "audit: 放行记录含 reason=allowed-non-master"
assert_audit_has_field "$AUDIT_LOG" tool_use_id tu_allow "audit: 放行记录含 tool_use_id"

# AC3: 审计记录可按 session_id 筛选，并能区分阻断与放行
# 同一 session_id=s_audit 下既有阻断（tu_blk, exit_code=2）又有放行（tu_allow, exit_code=0）
python3 - "$AUDIT_LOG" <<'PY'
import json, sys
log_path = sys.argv[1]
by_session = {"s_audit": []}
try:
    with open(log_path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            obj = json.loads(line)
            sid = obj.get("session_id", "")
            if sid == "s_audit":
                by_session["s_audit"].append(obj)
except FileNotFoundError:
    sys.exit(1)
records = by_session["s_audit"]
# 必须同时存在 exit_code=2（阻断）与 exit_code=0（放行），可按 exit_code 区分
exit_codes = {r.get("exit_code") for r in records}
if 2 in exit_codes and 0 in exit_codes and len(records) >= 2:
    sys.exit(0)
sys.exit(1)
PY
[ $? = 0 ] && PASS=$((PASS + 1)) || { FAIL=$((FAIL + 1)); FAILURES+=("[audit: AC3 按 session_id 筛选并区分阻断/放行] 失败"); }

# AC4: 记录不含文件内容/命令/token —— 输入里带敏感内容，断言日志不含
run_hook "$AUDIT_HOOK" '{"tool_name":"Write","tool_use_id":"tu_secret","session_id":"s_audit","tool_input":{"file_path":"'"$AUDIT_REPO"'/secret.py","content":"SUPER_SECRET_TOKEN=abc123","command":"rm -rf /"}}'
assert_exit 2 "audit: 含敏感内容的输入仍阻断"
assert_file_not_has_text "$AUDIT_LOG" "SUPER_SECRET_TOKEN" "audit: 日志不含文件内容"
assert_file_not_has_text "$AUDIT_LOG" "rm -rf" "audit: 日志不含 Bash 命令"
assert_file_not_has_text "$AUDIT_LOG" "abc123" "audit: 日志不含凭证值"

# AC: 非 Edit/Write 工具不审计（IK10CW out of scope）
lines_before_audit=$(grep -c '' "$AUDIT_LOG" 2>/dev/null || echo 0)
run_hook "$AUDIT_HOOK" '{"tool_name":"Read","tool_use_id":"tu_read","session_id":"s_audit","tool_input":{"file_path":"'"$AUDIT_REPO"'/c.py"}}'
assert_exit 0 "audit: 非 Edit/Write 工具放行"
lines_after_read=$(grep -c '' "$AUDIT_LOG" 2>/dev/null || echo 0)
[ "$lines_before_audit" = "$lines_after_read" ] && PASS=$((PASS + 1)) || { FAIL=$((FAIL + 1)); FAILURES+=("[audit: Read 不审计] 行数 before=$lines_before_audit after=$lines_after_read"); }

# AC: 仓库外文件不审计（IK10CW out of scope）
lines_before_audit=$(grep -c '' "$AUDIT_LOG" 2>/dev/null || echo 0)
run_hook "$AUDIT_HOOK" '{"tool_name":"Edit","tool_use_id":"tu_outside","session_id":"s_audit","tool_input":{"file_path":"/Users/x/.codex/config.toml"}}'
assert_exit 0 "audit: 仓库外文件放行"
lines_after_outside=$(grep -c '' "$AUDIT_LOG" 2>/dev/null || echo 0)
[ "$lines_before_audit" = "$lines_after_outside" ] && PASS=$((PASS + 1)) || { FAIL=$((FAIL + 1)); FAILURES+=("[audit: 仓库外不审计] 行数 before=$lines_before_audit after=$lines_after_outside"); }

# AC9: 审计目录不被 git 跟踪
assert_audit_not_tracked "$AUDIT_REPO" "$AUDIT_HOOK" "audit: 审计目录不出现在 git status/ls-files"

# AC6: 降级语义 —— 日志文件不可写时，exit code 与 stdout 契约不变，stderr 留降级提示
DEGRADE_REPO="$(mktemp -d)"
git -C "$DEGRADE_REPO" init -q
git -C "$DEGRADE_REPO" symbolic-ref HEAD refs/heads/master
DEGRADE_SAVED="${CLAUDE_PROJECT_DIR:-}"
export CLAUDE_PROJECT_DIR="$DEGRADE_REPO"
# 预创建只读日志文件，使追加失败 → 触发降级
mkdir -p "$DEGRADE_REPO/.git/hook-audit"
DEGRADE_LOG="$DEGRADE_REPO/.git/hook-audit/block-master-edit.sh.log"
touch "$DEGRADE_LOG"
chmod 000 "$DEGRADE_LOG"
run_hook "$AUDIT_HOOK" '{"tool_name":"Edit","tool_use_id":"tu_degrade","session_id":"s_audit","tool_input":{"file_path":"'"$DEGRADE_REPO"'/d.py"}}'
assert_exit 2 "audit: 降级时阻断 exit 2 不变"
assert_stdout_empty "audit: 降级时 stdout 保持为空"
assert_stderr_has "禁止在 master" "audit: 降级时保留既有阻断原因"
assert_stderr_has "hook-audit: degraded" "audit: 降级时 stderr 留降级提示"
chmod 644 "$DEGRADE_LOG" 2>/dev/null
export CLAUDE_PROJECT_DIR="$DEGRADE_SAVED"
rm -rf "$DEGRADE_REPO"
unset DEGRADE_REPO DEGRADE_SAVED DEGRADE_LOG

# AC6 补充：日志目录不可写（mkdir 失败）→ 同样降级，exit/stdout 契约不变
DEGRADE_DIR_REPO="$(mktemp -d)"
git -C "$DEGRADE_DIR_REPO" init -q
git -C "$DEGRADE_DIR_REPO" symbolic-ref HEAD refs/heads/master
DEGRADE_DIR_SAVED="${CLAUDE_PROJECT_DIR:-}"
export CLAUDE_PROJECT_DIR="$DEGRADE_DIR_REPO"
# 预创建 hook-audit 为文件而非目录，使 mkdir(parents) 失败 → 降级
touch "$DEGRADE_DIR_REPO/.git/hook-audit"
run_hook "$AUDIT_HOOK" '{"tool_name":"Edit","tool_use_id":"tu_degrade_dir","session_id":"s_audit","tool_input":{"file_path":"'"$DEGRADE_DIR_REPO"'/e.py"}}'
assert_exit 2 "audit: 目录不可写时阻断 exit 2 不变"
assert_stdout_empty "audit: 目录不可写时 stdout 保持为空"
assert_stderr_has "hook-audit: degraded" "audit: 目录不可写时 stderr 留降级提示"
export CLAUDE_PROJECT_DIR="$DEGRADE_DIR_SAVED"
rm -rf "$DEGRADE_DIR_REPO"
unset DEGRADE_DIR_REPO DEGRADE_DIR_SAVED

# AC5: 轮转 —— 活跃日志达到 10 MiB 时轮转，只保留 1 个归档
ROTATE_REPO="$(mktemp -d)"
git -C "$ROTATE_REPO" init -q
git -C "$ROTATE_REPO" symbolic-ref HEAD refs/heads/master
ROTATE_SAVED="${CLAUDE_PROJECT_DIR:-}"
export CLAUDE_PROJECT_DIR="$ROTATE_REPO"
ROTATE_LOG="$(audit_log_path "$ROTATE_REPO" "$AUDIT_HOOK")"
ROTATE_ARCHIVE="$(audit_log_archive_path "$ROTATE_REPO" "$AUDIT_HOOK")"
# 写一条记录建立日志，再灌填充到 ~9.99 MiB，再追加一条触发轮转
run_hook "$AUDIT_HOOK" '{"tool_name":"Edit","tool_use_id":"tu_fill1","session_id":"s_rot","tool_input":{"file_path":"'"$ROTATE_REPO"'/f.py"}}'
{ dd if=/dev/zero bs=1 count=$((10*1024*1024 - 200)) 2>/dev/null | tr '\0' 'X'; } >>"$ROTATE_LOG"
run_hook "$AUDIT_HOOK" '{"tool_name":"Edit","tool_use_id":"tu_fill2","session_id":"s_rot","tool_input":{"file_path":"'"$ROTATE_REPO"'/g.py"}}'
# 轮转后：归档存在且 >= 10MiB；活跃日志只含最后一条记录
assert_file_exists "$ROTATE_ARCHIVE" "audit: 轮转后归档存在"
[ "$(wc -c <"$ROTATE_ARCHIVE" 2>/dev/null)" -ge $((10*1024*1024 - 1000)) ] && PASS=$((PASS + 1)) || { FAIL=$((FAIL + 1)); FAILURES+=("[audit: 归档大小] 未达 10MiB"); }
assert_audit_line_count "$ROTATE_LOG" 1 "audit: 轮转后活跃日志只含 1 条"
# 第二次轮转：旧归档被替换，不产生 .log.2
{ dd if=/dev/zero bs=1 count=$((10*1024*1024 - 100)) 2>/dev/null | tr '\0' 'Y'; } >>"$ROTATE_LOG"
run_hook "$AUDIT_HOOK" '{"tool_name":"Edit","tool_use_id":"tu_fill3","session_id":"s_rot","tool_input":{"file_path":"'"$ROTATE_REPO"'/h.py"}}'
assert_file_exists "$ROTATE_ARCHIVE" "audit: 二次轮转后归档仍存在"
assert_audit_line_count "$ROTATE_LOG" 1 "audit: 二次轮转后活跃日志只含 1 条"
# 不存在 .log.2
if [ ! -e "${ROTATE_LOG}.2" ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); FAILURES+=("[audit: 不产生 .log.2] ${ROTATE_LOG}.2 不应存在"); fi
export CLAUDE_PROJECT_DIR="$ROTATE_SAVED"
rm -rf "$ROTATE_REPO"
unset ROTATE_REPO ROTATE_SAVED ROTATE_LOG ROTATE_ARCHIVE

# AC7: 并发追加 —— 多进程同时写不产生半行/丢失/拼接
CONCURRENT_REPO="$(mktemp -d)"
git -C "$CONCURRENT_REPO" init -q
git -C "$CONCURRENT_REPO" symbolic-ref HEAD refs/heads/master
CONCURRENT_SAVED="${CLAUDE_PROJECT_DIR:-}"
export CLAUDE_PROJECT_DIR="$CONCURRENT_REPO"
CONCURRENT_LOG="$(audit_log_path "$CONCURRENT_REPO" "$AUDIT_HOOK")"
# 20 个并发进程同时追加
python3 - "$HOOK_DIR/$AUDIT_HOOK" "$CONCURRENT_REPO" "$CONCURRENT_LOG" <<'PY'
import json, subprocess, sys, concurrent.futures
hook_path, project_dir, log_path = sys.argv[1], sys.argv[2], sys.argv[3]
def write_one(i):
    rec = {"tool_name":"Edit","tool_use_id":f"tu_c{i}","session_id":"s_conc","tool_input":{"file_path":f"{project_dir}/c{i}.py"}}
    payload = json.dumps(rec)
    env = {"CLAUDE_PROJECT_DIR": project_dir, "PATH": "/usr/bin:/bin"}
    r = subprocess.run(["bash", hook_path], input=payload.encode(), capture_output=True, env=env)
    return r.returncode
with concurrent.futures.ThreadPoolExecutor(max_workers=20) as ex:
    codes = list(ex.map(write_one, range(20)))
sys.exit(0 if all(c == 2 for c in codes) else 1)
PY
[ $? = 0 ] && PASS=$((PASS + 1)) || { FAIL=$((FAIL + 1)); FAILURES+=("[audit: 并发 Gate 退出码] 存在非 exit 2"); }
# 断言：20 行、全部合法 JSON、tool_use_id 唯一
actual_lines=$(grep -c '' "$CONCURRENT_LOG" 2>/dev/null || echo 0)
[ "$actual_lines" = "20" ] && PASS=$((PASS + 1)) || { FAIL=$((FAIL + 1)); FAILURES+=("[audit: 并发行数] actual=$actual_lines expected=20"); }
python3 - "$CONCURRENT_LOG" <<'PY'
import json, sys
log_path = sys.argv[1]
seen = set()
ok = True
try:
    with open(log_path) as f:
        for line in f:
            line = line.strip()
            if not line:
                ok = False
                break
            obj = json.loads(line)  # raises on half/corrupt line
            tid = obj.get("tool_use_id", "")
            if tid in seen:
                ok = False
                break
            seen.add(tid)
    ok = ok and len(seen) == 20
except Exception:
    ok = False
sys.exit(0 if ok else 1)
PY
[ $? = 0 ] && PASS=$((PASS + 1)) || { FAIL=$((FAIL + 1)); FAILURES+=("[audit: 并发完整性] 存在半行/丢失/拼接/重复"); }
export CLAUDE_PROJECT_DIR="$CONCURRENT_SAVED"
rm -rf "$CONCURRENT_REPO"
unset CONCURRENT_REPO CONCURRENT_SAVED CONCURRENT_LOG

export CLAUDE_PROJECT_DIR="$SAVED_CLAUDE_PROJECT_DIR_AUDIT"
rm -rf "$AUDIT_REPO" "$AUDIT_REPO-wt"
unset AUDIT_HOOK AUDIT_REPO AUDIT_LOG SAVED_CLAUDE_PROJECT_DIR_AUDIT

# Slice 4.8 — block-master-edit 审计回归（IK10CW review fixes）
AUDIT_HOOK=block-master-edit.sh

# 回归：file_path 为对象/数组时，审计记录不泄漏嵌入内容（str() 会序列化嵌套结构）
POLLUTION_REPO="$(mktemp -d)"
git -C "$POLLUTION_REPO" init -q
git -C "$POLLUTION_REPO" symbolic-ref HEAD refs/heads/master
POLLUTION_LOG="$(audit_log_path "$POLLUTION_REPO" "$AUDIT_HOOK")"
# 对象 file_path —— 在 master 仓库内跑确保阻断并审计；重点断言不泄漏嵌入值
( cd "$POLLUTION_REPO" && printf '%s' '{"tool_name":"Edit","tool_use_id":"tu_obj","session_id":"s","tool_input":{"file_path":{"nested":"SECRET_OBJ_VALUE"},"content":"file body"}}' | bash "${HOOK_DIR}/${AUDIT_HOOK}" ) 2>/dev/null
assert_file_not_has_text "$POLLUTION_LOG" "SECRET_OBJ_VALUE" "audit-regress: 对象 file_path 不泄漏嵌入值"
assert_file_not_has_text "$POLLUTION_LOG" "file body" "audit-regress: content 字段不入日志"
# 数组 file_path —— str(["SECRET"]) 会泄漏
( cd "$POLLUTION_REPO" && printf '%s' '{"tool_name":"Edit","tool_use_id":"tu_arr","session_id":"s","tool_input":{"file_path":["SECRET_ARR_VALUE"]}}' | bash "${HOOK_DIR}/${AUDIT_HOOK}" ) 2>/dev/null
assert_file_not_has_text "$POLLUTION_LOG" "SECRET_ARR_VALUE" "audit-regress: 数组 file_path 不泄漏嵌入值"
# 对象型 session_id/tool_use_id 也必须置空，且日志记录仍存在
run_hook "$AUDIT_HOOK" '{"tool_name":"Edit","tool_use_id":"tu_session_obj","session_id":{"token":"SECRET_SESSION_VALUE"},"tool_input":{"file_path":"'"$POLLUTION_REPO"'/session.py"}}'
assert_exit 2 "audit-regress: 对象 session_id 不改变 master 阻断"
run_hook "$AUDIT_HOOK" '{"tool_name":"Edit","tool_use_id":{"mcp":"SECRET_TOOL_USE_VALUE"},"session_id":"s_tool_obj","tool_input":{"file_path":"'"$POLLUTION_REPO"'/tool.py"}}'
assert_exit 2 "audit-regress: 对象 tool_use_id 不改变 master 阻断"
assert_file_not_has_text "$POLLUTION_LOG" "SECRET_SESSION_VALUE" "audit-regress: 对象 session_id 不泄漏嵌入值"
assert_file_not_has_text "$POLLUTION_LOG" "SECRET_TOOL_USE_VALUE" "audit-regress: 对象 tool_use_id 不泄漏嵌入值"
python3 - "$POLLUTION_LOG" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    records = [json.loads(line) for line in f if line.strip()]
by_tool_use = {r.get("tool_use_id"): r for r in records}
tool_object = next((r for r in records if r.get("session_id") == "s_tool_obj"), None)
ok = (
    by_tool_use.get("tu_obj", {}).get("file_path") == ""
    and by_tool_use.get("tu_arr", {}).get("file_path") == ""
    and by_tool_use.get("tu_session_obj", {}).get("session_id") == ""
    and tool_object is not None
    and tool_object.get("tool_use_id") == ""
)
sys.exit(0 if ok else 1)
PY
[ $? = 0 ] && PASS=$((PASS + 1)) || { FAIL=$((FAIL + 1)); FAILURES+=("[audit-regress: 类型污染记录] 记录缺失或非标量字段未置空"); }
# 数字/布尔关联标识保留文本形式（安全）
run_hook "$AUDIT_HOOK" '{"tool_name":"Edit","tool_use_id":99,"session_id":true,"tool_input":{"file_path":"'"$POLLUTION_REPO"'/n.py"}}'
assert_audit_has_field "$POLLUTION_LOG" tool_use_id 99 "audit-regress: 数字 tool_use_id 保留文本形式"
assert_audit_has_field "$POLLUTION_LOG" session_id true "audit-regress: 布尔 session_id 保留文本形式"
rm -rf "$POLLUTION_REPO"
unset POLLUTION_REPO POLLUTION_LOG

# 回归：审计写入 file_path 所属工作树的 common dir，不污染主 checkout 真实审计流
# 原理：脚本用 TOPLEVEL（file_path 解析）而非 CLAUDE_PROJECT_DIR（会话级）定位审计目录。
REAL_AUDIT_DIR="$(dirname "$(audit_log_path "$REPO_ROOT" "$AUDIT_HOOK")")"
ISOLATION_REPO="$(mktemp -d)"
git -C "$ISOLATION_REPO" init -q
git -C "$ISOLATION_REPO" symbolic-ref HEAD refs/heads/master
real_before=$( { grep -c '' "$REAL_AUDIT_DIR/block-master-edit.sh.log" 2>/dev/null || echo 0; } )
run_hook "$AUDIT_HOOK" '{"tool_name":"Edit","tool_use_id":"tu_iso","session_id":"s_iso","tool_input":{"file_path":"'"$ISOLATION_REPO"'/iso.py"}}'
assert_exit 2 "audit-regress: 隔离仓库 master 阻断"
real_after=$( { grep -c '' "$REAL_AUDIT_DIR/block-master-edit.sh.log" 2>/dev/null || echo 0; } )
[ "$real_before" = "$real_after" ] && PASS=$((PASS + 1)) || { FAIL=$((FAIL + 1)); FAILURES+=("[audit-regress: 不污染真实流] real before=$real_before after=$real_after"); }
# 事件应落在隔离仓库自己的审计目录
assert_audit_has_field "$(audit_log_path "$ISOLATION_REPO" "$AUDIT_HOOK")" tool_use_id tu_iso "audit-regress: 事件落在 file_path 所属工作树"
rm -rf "$ISOLATION_REPO"
unset ISOLATION_REPO real_before real_after REAL_AUDIT_DIR

# 回归：并发触发轮转 —— 多进程同时跨越 10MiB 阈值，不产生半行/丢失/拼接
CONCROT_REPO="$(mktemp -d)"
git -C "$CONCROT_REPO" init -q
git -C "$CONCROT_REPO" symbolic-ref HEAD refs/heads/master
CONCROT_LOG="$(audit_log_path "$CONCROT_REPO" "$AUDIT_HOOK")"
CONCROT_ARCHIVE="$(audit_log_archive_path "$CONCROT_REPO" "$AUDIT_HOOK")"
# 预填 active 到接近 10MiB（差 100 bytes），使第一条并发追加即触发追加后轮转。
# 填充行本身是完整 JSON 审计形状，避免通过“跳过非 JSON 行”掩盖拼接问题。
echo '{"tool_name":"Edit","tool_use_id":"tu_seed","session_id":"s","tool_input":{"file_path":"'"$CONCROT_REPO"'/seed.py"}}' | bash "${HOOK_DIR}/${AUDIT_HOOK}" 2>/dev/null
python3 - "$CONCROT_LOG" "$CONCROT_REPO" <<'PY'
import json, os, sys
log_path, repo = sys.argv[1], sys.argv[2]
target = 10 * 1024 * 1024 - 100
record = {
    "timestamp": "fixture",
    "hook": "block-master-edit.sh",
    "tool": "Edit",
    "file_path": f"{repo}/padding.py",
    "branch": "master",
    "session_id": "s_cr",
    "tool_use_id": "tu_pad",
    "exit_code": 2,
    "reason": "fixture-padding",
    "padding": "",
}
current = os.path.getsize(log_path)
base = json.dumps(record, ensure_ascii=False, separators=(",", ":"))
padding_size = target - current - len(base.encode()) - 1
if padding_size < 0:
    sys.exit(1)
record["padding"] = "Z" * padding_size
line = json.dumps(record, ensure_ascii=False, separators=(",", ":")) + "\n"
with open(log_path, "a") as f:
    f.write(line)
sys.exit(0 if os.path.getsize(log_path) == target else 1)
PY
[ $? = 0 ] && PASS=$((PASS + 1)) || { FAIL=$((FAIL + 1)); FAILURES+=("[audit-regress: 并发轮转合法 JSON 填充] 未精确填充到 10MiB-100"); }
# 15 个并发进程同时追加（第一个跨越阈值触发轮转，其余追加到新 active）
python3 - "$HOOK_DIR/$AUDIT_HOOK" "$CONCROT_REPO" "$CONCROT_LOG" "$CONCROT_ARCHIVE" <<'PY'
import json, subprocess, sys, concurrent.futures
hook_path, repo, log_path, archive_path = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
def write_one(i):
    rec = {"tool_name":"Edit","tool_use_id":f"tu_cr{i}","session_id":"s_cr","tool_input":{"file_path":f"{repo}/cr{i}.py"}}
    r = subprocess.run(["bash", hook_path], input=json.dumps(rec).encode(), capture_output=True, env={"PATH":"/usr/bin:/bin"})
    return r.returncode
with concurrent.futures.ThreadPoolExecutor(max_workers=15) as ex:
    codes = list(ex.map(write_one, range(15)))
# 汇总：active + archive 的所有行必须全部合法 JSON、tool_use_id 唯一
seen = set()
ok = True
for path in (log_path, archive_path):
    try:
        with open(path) as f:
            for line in f:
                line = line.strip()
                if not line:
                    ok = False
                    break
                try:
                    obj = json.loads(line)
                except Exception:
                    ok = False
                    break
                tid = obj.get("tool_use_id", "")
                if tid in seen:
                    ok = False
                    break
                seen.add(tid)
    except FileNotFoundError:
        pass
# seed + 合法 JSON 填充 + 15 并发：返回码必须全为 2，ID 集合必须精确相等。
expected = {"tu_seed", "tu_pad", *(f"tu_cr{i}" for i in range(15))}
ok = ok and all(code == 2 for code in codes) and seen == expected
sys.exit(0 if ok else 1)
PY
[ $? = 0 ] && PASS=$((PASS + 1)) || { FAIL=$((FAIL + 1)); FAILURES+=("[audit-regress: 并发轮转完整性] 半行/丢失/拼接/重复"); }
# 轮转后活跃日志不超过 10MiB
if [ -f "$CONCROT_LOG" ]; then
  concrot_sz=$(wc -c < "$CONCROT_LOG")
  [ "$concrot_sz" -lt $((10*1024*1024)) ] && PASS=$((PASS + 1)) || { FAIL=$((FAIL + 1)); FAILURES+=("[audit-regress: 并发轮转后 active < 10MiB] size=$concrot_sz"); }
else
  PASS=$((PASS + 1))
fi
rm -rf "$CONCROT_REPO"
unset CONCROT_REPO CONCROT_LOG CONCROT_ARCHIVE concrot_sz
unset AUDIT_HOOK

# Slice 5 — Codex project hook layer
assert_hook_contract_drift_detection
assert_hook_audit_coverage_detection
assert_closed_loop_gate_drift_detection
run_hook_contract_check
assert_exit 0 "contracts: 真实四端 Hook 配置满足共享契约"
assert_stdout_empty "contracts: 真实四端 Hook 配置 stdout 为空"
assert_stderr_empty "contracts: 真实四端 Hook 配置 stderr 为空"
assert_file_exists "$HOOK_CLOSED_LOOP_CHECKER" "closed-loop: 四端配置链闭环检查器存在"
run_command_hook "python3 \"$HOOK_CLOSED_LOOP_CHECKER\"" ""
assert_exit 0 "closed-loop: 四端配置链闭环检查通过"
assert_stdout_has "[配置链集成] ZCode" "closed-loop: 报告含 ZCode 配置链证据"
assert_stdout_has "[配置链集成] Claude Code" "closed-loop: 报告含 Claude Code 配置链证据"
assert_stdout_has "[配置链集成] Codex" "closed-loop: 报告含 Codex 配置链证据"
assert_stdout_has "[配置链集成] Kimi CLI" "closed-loop: 报告含 Kimi CLI 配置链证据"
assert_stdout_has "audit=16/16 unique correlated records" "closed-loop: 报告含唯一审计关联证据"
assert_stdout_has "[直接 Gate 黑盒]" "closed-loop: 报告区分直接 Gate 黑盒"
assert_stdout_has "[外部客户端实机探针] 未执行" "closed-loop: 报告不冒充外部客户端实机证据"
assert_stderr_empty "closed-loop: 成功时 stderr 为空"
assert_file_exists "$CODEX_HOOKS_JSON" "codex: hooks.json 存在"
assert_codex_hooks_valid "codex: hooks.json 与 Claude matcher 同步"
for runtime_hook in .claude/hooks/*.sh .codex/hooks/*.sh .kimi-code/hooks/*.sh .claude/settings.json .codex/hooks.json .kimi-code/hooks.toml; do
  assert_file_not_matches "$runtime_hook" 'permissionDecision[^[:alnum:]]*[=:][^[:alnum:]]*ask' "hooks: $runtime_hook 不包含 ask 运行机制"
done
for active_doc in CLAUDE.md CONTEXT.md docs/agents/git-workflow.md docs/agents/commit-and-review.md docs/agents/worktree-workflow.md docs/agents/hooks/README.md; do
  assert_file_not_has_text "$active_doc" 'permissionDecision=ask' "docs: $active_doc 不再描述 ask 为活跃机制"
done
assert_git_not_ignored ".codex/hooks.json" "codex: hooks.json 可提交"
assert_git_not_ignored ".codex/hooks/run-claude-pretool.sh" "codex: wrapper 可提交"
assert_git_ignored "CLAUDE.local.md" "claude: CLAUDE.local.md 保持本机私有"
assert_git_ignored ".codex/config.toml" "codex: config.toml 保持私密"
assert_git_ignored ".codex/local.json" "codex: 其它本机配置保持私密"
assert_git_ignored ".codex/hooks/other.sh" "codex: 禁止提交复制出来的 hook 实现"
assert_git_not_ignored ".kimi-code/hooks.toml" "kimi: hooks.toml 可提交"
assert_git_not_ignored ".kimi-code/hooks/blue-whale-hook.sh" "kimi: shim 可提交"
assert_git_ignored ".kimi-code/local.toml" "kimi: local.toml 保持本机私有"

# 可重复运行时探针必须从真实 Codex 配置一路驱动到共享 Gate，并输出稳定摘要。
assert_file_exists "$CODEX_WRITE_PROBE" "codex probe: 探针存在"
run_command_hook "bash \"$CODEX_WRITE_PROBE\"" ""
assert_exit 0 "codex probe: 运行成功"
assert_stdout_has "matcher=Edit|Write" "codex probe: 锁定 matcher"
assert_stdout_has "tool_name=apply_patch" "codex probe: 锁定实际工具名"
assert_stdout_has "tool_input=command" "codex probe: 锁定输入字段"
assert_stdout_has "master create=blocked" "codex probe: master 创建被阻断"
assert_stdout_has "master update=blocked" "codex probe: master 修改被阻断"
assert_stdout_has "task create=allowed" "codex probe: 任务区创建放行"
assert_stdout_has "task update=allowed" "codex probe: 任务区修改放行"
assert_stderr_empty "codex probe: 成功时 stderr 为空"

# Codex 官方 PreToolUse 形状：matcher 命中 Edit|Write，但 wrapper 收到的
# tool_name 仍为 apply_patch，补丁正文位于 tool_input.command，路径相对 session cwd。
CODEX_PATCH_ROOT="$(mktemp -d)"
CODEX_PATCH_MASTER="$CODEX_PATCH_ROOT/master"
CODEX_PATCH_FEATURE="$CODEX_PATCH_ROOT/feature"
mkdir -p "$CODEX_PATCH_MASTER" "$CODEX_PATCH_FEATURE"
git -C "$CODEX_PATCH_MASTER" init -q
git -C "$CODEX_PATCH_MASTER" symbolic-ref HEAD refs/heads/master
git -C "$CODEX_PATCH_FEATURE" init -q
git -C "$CODEX_PATCH_FEATURE" symbolic-ref HEAD refs/heads/feature/x
printf 'before\n' >"$CODEX_PATCH_MASTER/existing.txt"
printf 'before\n' >"$CODEX_PATCH_FEATURE/existing.txt"

run_command_hook "$CODEX_MASTER_EDIT_CMD" "$(printf '{\"tool_name\":\"apply_patch\",\"cwd\":\"%s\",\"tool_input\":{\"command\":\"*** Begin Patch\\n*** Add File: created.txt\\n+created\\n*** End Patch\"}}' "$CODEX_PATCH_MASTER")"
assert_exit 2 "codex apply_patch: master 创建文件由共享 Gate 拦截"

run_command_hook "$CODEX_MASTER_EDIT_CMD" "$(printf '{\"tool_name\":\"apply_patch\",\"cwd\":\"%s\",\"tool_input\":{\"command\":\"*** Begin Patch\\n*** Add File: created.txt\\n+created\\n*** End Patch\"}}' "$CODEX_PATCH_FEATURE")"
assert_exit 0 "codex apply_patch: feature 创建文件由共享 Gate 放行"

run_command_hook "$CODEX_MASTER_EDIT_CMD" "$(printf '{\"tool_name\":\"apply_patch\",\"cwd\":\"%s\",\"tool_input\":{\"command\":\"*** Begin Patch\\n*** Update File: existing.txt\\n@@\\n-before\\n+after\\n*** End Patch\"}}' "$CODEX_PATCH_MASTER")"
assert_exit 2 "codex apply_patch: master 修改文件由共享 Gate 拦截"

run_command_hook "$CODEX_MASTER_EDIT_CMD" "$(printf '{\"tool_name\":\"apply_patch\",\"cwd\":\"%s\",\"tool_input\":{\"command\":\"*** Begin Patch\\n*** Update File: existing.txt\\n@@\\n-before\\n+after\\n*** End Patch\"}}' "$CODEX_PATCH_FEATURE")"
assert_exit 0 "codex apply_patch: feature 修改文件由共享 Gate 放行"

# 第一个目标位于 feature、第二个目标位于 master：wrapper 必须逐目标执行，
# 不能因首个目标放行而漏掉后续工作树中的 master 写入。
run_command_hook "$CODEX_MASTER_EDIT_CMD" "$(printf '{\"tool_name\":\"apply_patch\",\"cwd\":\"%s\",\"tool_input\":{\"command\":\"*** Begin Patch\\n*** Add File: feature-only.txt\\n+allowed\\n*** Update File: ../master/existing.txt\\n@@\\n-before\\n+blocked\\n*** End Patch\"}}' "$CODEX_PATCH_FEATURE")"
assert_exit 2 "codex apply_patch: 多工作树补丁含 master 目标时拦截"

# Update 源文件位于 feature，但 Move to 目标位于 master：源与目标都必须经过共享 Gate。
run_command_hook "$CODEX_MASTER_EDIT_CMD" "$(printf '{\"tool_name\":\"apply_patch\",\"cwd\":\"%s\",\"tool_input\":{\"command\":\"*** Begin Patch\\n*** Update File: existing.txt\\n*** Move to: ../master/moved.txt\\n@@\\n-before\\n+after\\n*** End Patch\"}}' "$CODEX_PATCH_FEATURE")"
assert_exit 2 "codex apply_patch: Move to master 目标由共享 Gate 拦截"

run_command_hook "$CODEX_MASTER_EDIT_CMD" "$(printf '{\"tool_name\":\"apply_patch\",\"cwd\":\"%s\",\"tool_input\":{\"command\":\"*** Begin Patch\\n*** Update File: existing.txt\\n*** Move to: moved.txt\\n@@\\n-before\\n+after\\n*** End Patch\"}}' "$CODEX_PATCH_FEATURE")"
assert_exit 0 "codex apply_patch: Move to feature 目标由共享 Gate 放行"

run_command_hook "$CODEX_MASTER_EDIT_CMD" "$(printf '{\"tool_name\":\"apply_patch\",\"cwd\":\"%s\",\"tool_input\":{\"command\":\"*** Begin Patch\\n*** Add File: feature-only.txt\\n+allowed\\n*** Delete File: ../master/existing.txt\\n*** End Patch\"}}' "$CODEX_PATCH_FEATURE")"
assert_exit 2 "codex apply_patch: Delete master 目标由共享 Gate 拦截"

run_command_hook "$CODEX_MASTER_EDIT_CMD" "$(printf '{\"tool_name\":\"apply_patch\",\"cwd\":\"%s\",\"tool_input\":{\"command\":\"*** Begin Patch\\n*** Update File: existing.txt\\n*** Move to:\\n@@\\n-before\\n+after\\n*** End Patch\"}}' "$CODEX_PATCH_FEATURE")"
assert_exit 2 "codex apply_patch: 部分可解析但 Move 目标畸形时 fail closed"

run_command_hook "$CODEX_MASTER_EDIT_CMD" "$(printf '{\"tool_name\":\"apply_patch\",\"cwd\":\"%s\",\"tool_input\":{\"command\":\"*** Begin Patch\\n*** End Patch\"}}' "$CODEX_PATCH_FEATURE")"
assert_exit 2 "codex apply_patch: 无法解析目标时 fail closed"
assert_stderr_has "apply_patch" "codex apply_patch: fail closed 提示含输入类型"

rm -rf "$CODEX_PATCH_ROOT"
unset CODEX_PATCH_ROOT CODEX_PATCH_MASTER CODEX_PATCH_FEATURE

# Slice 5.5 — 用户本地集成区 / Agent 任务区边界
WRITE_PREFLIGHT_HEADING="## 写入前自检（每次写操作前强制执行）"
assert_markdown_section_has_text "CLAUDE.md" "$WRITE_PREFLIGHT_HEADING" "摘要是约束声明，自检是执行机制" "workflow: 自检说明与红线摘要的关系"
assert_markdown_section_has_text "CLAUDE.md" "$WRITE_PREFLIGHT_HEADING" "Edit、Write 或任何会改变 Git 状态的操作前" "workflow: 自检覆盖所有仓库写操作"
assert_markdown_section_has_text "CLAUDE.md" "$WRITE_PREFLIGHT_HEADING" "确认当前分支" "workflow: 自检确认当前分支"
assert_markdown_section_has_text "CLAUDE.md" "$WRITE_PREFLIGHT_HEADING" "scripts/start-task-worktree.sh" "workflow: 自检指向唯一 Work Tree 入口"
assert_markdown_section_has_text "CLAUDE.md" "$WRITE_PREFLIGHT_HEADING" "确认目标路径" "workflow: 自检确认目标路径"
assert_markdown_section_has_text "CLAUDE.md" "$WRITE_PREFLIGHT_HEADING" "用户本地集成区（master 主检出区）" "workflow: 自检识别主检出区"
assert_markdown_section_has_text "CLAUDE.md" "$WRITE_PREFLIGHT_HEADING" "确认 Git 写入区域" "workflow: 自检确认 Git 写入区域"
assert_markdown_section_has_text "CLAUDE.md" "$WRITE_PREFLIGHT_HEADING" "工单分支" "workflow: 自检要求工单分支"
assert_markdown_section_has_text "CLAUDE.md" "$WRITE_PREFLIGHT_HEADING" "立即停止写入" "workflow: 自检失败时停止写入"
assert_file_has_text "docs/agents/git-workflow.md" "防御顺序：规范前置 → Hook 兜底" "workflow: Git 规则保持规范前置"
assert_file_has_text "docs/agents/commit-and-review.md" "规范前置 → Hook 兜底" "workflow: 协作文档保持规范前置"
assert_file_not_has_text ".githooks/pre-commit" "禁止在 master/main 上提交" "workflow: pre-commit 不再拦用户本地 master commit"
assert_file_not_has_text "scripts/start-task-worktree.sh" "git worktree" "workflow: shell 入口不复制 Git 业务逻辑"
assert_file_not_has_text "scripts/cleanup-task-worktree.sh" "sync-master.sh" "workflow: cleanup-task-worktree 不再同步用户本地 master"
assert_file_not_has_text "scripts/publish-review-package.sh" "任务 worktree 内执行" "workflow: publish-review-package 支持发布包装分支"
assert_file_has_text "scripts/start-task-worktree.py" '"fetch", "origin", "master"' "workflow: Python 入口先 fetch origin/master"
assert_file_has_text "scripts/start-task-worktree.py" '"merge", "--ff-only", "origin/master"' "workflow: 远程领先时 fast-forward"
assert_file_has_text "scripts/start-task-worktree.py" '"--no-ff"' "workflow: 分叉时普通 merge"
assert_file_has_text "scripts/start-task-worktree.py" '"worktree", "add", str(target), "-b", branch, base_sha' "workflow: worktree 基于同步后的精确 SHA"
assert_file_has_text "AGENTS.md" '`CLAUDE.md` 是本仓库团队 Agent 规则的唯一权威源' "workflow: AGENTS 索引 CLAUDE 权威源"
assert_file_has_text "docs/agents/hooks/README.md" "python3 scripts/check-hook-closed-loop.py" "workflow: 新人路径包含三端闭环检查"
assert_file_has_text "docs/agents/hooks/README.md" "python3 scripts/query-hook-audit.py" "workflow: 新人路径包含审计查询入口"
assert_file_has_text "docs/agents/hooks/README.md" "未进入仓库 Hook 执行链" "workflow: 新人路径包含缺失调用标识诊断"
assert_file_has_text "docs/agents/hooks/README.md" "不能解释外部 harness 的内部根因" "workflow: 新人路径保持外部 harness 诊断边界"
assert_file_has_text "docs/agents/hooks/README.md" "直接 Gate 黑盒" "workflow: 文档区分直接 Gate 黑盒证据"
assert_file_has_text "docs/agents/hooks/README.md" "配置链集成" "workflow: 文档区分配置链集成证据"
assert_file_has_text "docs/agents/hooks/README.md" "外部客户端实机探针" "workflow: 文档区分外部客户端实机证据"
assert_file_not_has_text "scripts/merge-task-to-local-master.sh" "不允许含非 ASCII" "workflow: 本地合入不再拒绝中文分支"
assert_file_has_text ".githooks/pre-push" '--validate-branch "$branch"' "workflow: pre-push 复用结构化中文分支校验器"
assert_file_not_has_text ".githooks/pre-push" "纯 shell，零依赖" "workflow: pre-push 不再宣称零依赖"
assert_file_has_text "scripts/setup-hooks.sh" "Python 3" "workflow: 初始化说明披露 pre-push 的 Python 3 依赖"

setup_git_stub
export FAKE_BRANCH=feature/x

# Codex 包装命令必须能从 repo root 调到 .claude/hooks 权威脚本。
run_command_hook "$CODEX_BLOCK_PUSH_CMD" '{"tool_input":{"command":"git push origin master"}}'
assert_exit 2 "codex: push master 包装命令拦截"
assert_stderr_has "master" "codex: push master 包装命令提示"

run_command_hook "$CODEX_DANGER_CMD" '{"tool_input":{"command":"git push --force origin feature/x"}}'
assert_exit 2 "codex: dangerous git 包装命令拦截"
assert_stderr_has "--force" "codex: dangerous git 包装命令提示"

run_command_hook "$CODEX_DANGER_CMD" '{"tool_input":{"command":"git push --force-with-lease origin feature/x"}}'
assert_exit 0 "codex: force-with-lease 工单分支放行"

# Codex 端 squash 检查已并入 confirm-release-action.sh（通过 run-claude-pretool.sh 转发）。
# block-squash-merge.sh 不再在 .codex/hooks.json 注册，故用 CODEX_RELEASE_CMD 验证。
run_command_hook "$CODEX_RELEASE_CMD" '{"tool_name":"mcp__gitee-ent__merge_enterprise_pull","tool_input":{"merge_method":"squash"}}'
assert_exit 2 "codex: squash merge 包装命令拦截"
assert_stderr_has "squash" "codex: squash merge 提示含 squash"

run_command_hook "$CODEX_ISSUE_CMD" '{"tool_name":"mcp__gitee-ent__update_enterprise_issue","tool_input":{"issue_id":"IJZ5WA","issue_state_id":123,"label_ids":"342812299"}}'
assert_exit 0 "codex: 普通 update issue 放行"

run_command_hook "$CODEX_ISSUE_CMD" '{"tool_name":"mcp__gitee-ent__update_enterprise_issue","tool_input":{"issue_id":"IJZ74J","parent_id":33553306}}'
assert_exit 2 "codex: update 子 issue 缺归属拦截"

run_command_hook "$CODEX_RELEASE_CMD" '{"tool_name":"mcp__gitee-ent__create_enterprise_repo_pull","tool_input":{"source_branch":"feature/x","target_branch":"master","draft":"true","title":"test"}}'
assert_exit 2 "codex: draft PR 包装命令拦截"
assert_stderr_has "不使用 draft PR" "codex: draft PR 包装命令提示普通 PR"

run_command_hook "$CODEX_RELEASE_CMD" '{"tool_input":{"command":"git push -u origin feature/x"}}'
assert_exit 2 "codex: 直接 git push 包装命令拦截"
assert_stderr_has "直接 git push" "codex: 直接 git push 包装命令提示"

run_command_hook "$CODEX_RELEASE_CMD" '{"tool_input":{"command":"scripts/publish-review-package.sh --user-authorized"}}'
assert_exit 2 "codex: release 缺模式被拦"

run_command_hook "$CODEX_RELEASE_CMD" '{"tool_input":{"command":"scripts/publish-review-package.sh --user-authorized --update-pr 65 --pr-snapshot /tmp/pr-65.json"}}'
assert_exit 0 "codex: release update 授权入口无交互放行"
assert_stdout_empty "codex: release update 授权入口无输出"

run_command_hook "$CODEX_RELEASE_CMD" '{"tool_input":{"command":"git commit -m \"feat: task slice\""}}'
assert_exit 2 "codex: direct commit 硬阻断"
assert_stderr_has "commit-task-for-review.sh -m" "codex: direct commit 指向标准入口"

run_command_hook "$CODEX_RELEASE_CMD" '{"tool_input":{"command":"git commit --amend"}}'
assert_exit 2 "codex: direct commit --amend 硬阻断"
assert_stderr_has "commit-task-for-review.sh --amend" "codex: direct commit --amend 文案含 --amend 指引"

run_command_hook "$CODEX_RELEASE_CMD" '{"tool_input":{"command":"scripts/merge-task-to-local-master.sh --user-authorized feature/x"}}'
assert_exit 0 "codex: local merge 授权入口无交互放行"
assert_stdout_empty "codex: local merge 授权入口无输出"

# 一次性凭证依赖真实 git common-dir/hash-object；前面的 fake git 只用于分支查询型 gate。
teardown_git_stub
unset FAKE_BRANCH

setup_action_test_repo
write_action_marker merge-pr 16660949 48854568 31
run_command_hook "$CODEX_RELEASE_CMD" '{"tool_use_id":"codex-merge-31","tool_name":"mcp__gitee-ent__merge_enterprise_pull","tool_input":{"enterprise_id":16660949,"project_id":"48854568","pull_request_id":31,"merge_method":"merge"}}'
assert_exit 0 "codex: merge PR 有凭证放行"
assert_file_exists "$(authorization_marker_path merge-pr 16660949 48854568 31)" "codex: merge PR Pre 保留凭证"

run_command_hook "$CODEX_RELEASE_POST_CMD" '{"hook_event_name":"PostToolUse","tool_use_id":"codex-merge-31","tool_name":"mcp__gitee-ent__merge_enterprise_pull","tool_input":{"enterprise_id":16660949,"project_id":"48854568","pull_request_id":31,"merge_method":"merge"},"tool_response":{"isError":false}}'
assert_exit 0 "codex: merge PR Post 放行"
assert_file_missing "$(authorization_marker_path merge-pr 16660949 48854568 31)" "codex: merge PR Post 消费凭证"
teardown_action_test_repo

# Slice 6 — cleanup-release-branch.sh（真实临时 git 仓库集成测试）
# 现有夹具只做 hook 层黑盒；本组用真实裸 origin + clone 仓库驱动
# cleanup-release-branch.sh 的公共 CLI 行为（exit code + git 副作用）。
# 夹具：mktemp 临时仓库，cp 真实 scripts/lib/worktree-paths.sh + 待测脚本进去，
# ROOT 取到临时仓库、lib 能 source 到、git 操作隔离（不碰真实仓库）。

# run_repo_script <cwd> <script-and-args...>
# 在 cwd 下跑脚本，捕获 exit→RUN_EXIT / stdout→RUN_STDOUT / stderr→RUN_STDERR（与 run_hook 同口径）。
run_repo_script() {
  local cwd="$1"; shift
  local out err
  out="$(mktemp)"; err="$(mktemp)"
  ( cd "$cwd" && bash "$@" ) >"$out" 2>"$err"
  RUN_EXIT=$?
  RUN_STDOUT="$(cat "$out")"
  RUN_STDERR="$(cat "$err")"
  rm -f "$out" "$err"
}

# build_repo_at <repo-path> <origin-path>
# 在指定路径建一个干净的 master 仓库（含待测脚本 + lib），远端推一个 bare origin。
build_repo_at() {
  local repo="$1" origin="$2"
  git init --bare "$origin" >/dev/null 2>&1
  git init "$repo" >/dev/null 2>&1
  mkdir -p "$repo/scripts/lib"
  cp "$REPO_ROOT/scripts/lib/worktree-paths.sh" "$repo/scripts/lib/"
  cp "$REPO_ROOT/scripts/cleanup-release-branch.sh" "$repo/scripts/"
  (
    cd "$repo"
    git config user.email t@t
    git config user.name t
    git config core.editor true
    git commit --allow-empty -m init >/dev/null 2>&1
    git add scripts
    git commit -m "add scripts" >/dev/null 2>&1
    git branch -M master
    git remote add origin "$origin"
    git push -q origin master >/dev/null 2>&1
  )
}

RELEASE_TMP_LIST=()
# setup_release_repo：建一个标准主 checkout 形态仓库（非 worktree），路径存 RELEASE_TMP 供子测试用。
setup_release_repo() {
  RELEASE_TMP="$(mktemp -d)"
  RELEASE_TMP_LIST+=("$RELEASE_TMP")
  build_repo_at "$RELEASE_TMP/main" "$RELEASE_TMP/origin.git"
}
teardown_release_repos() {
  for t in "${RELEASE_TMP_LIST[@]}"; do rm -rf "$t"; done
}

# L1 — 参数层
setup_release_repo
run_repo_script "$RELEASE_TMP/main" scripts/cleanup-release-branch.sh
assert_exit 1 "release-cleanup: 缺 --user-authorized 拦截"
assert_stderr_has "缺少 --user-authorized" "release-cleanup: 缺授权提示"

setup_release_repo
run_repo_script "$RELEASE_TMP/main" scripts/cleanup-release-branch.sh --user-authorized
assert_exit 1 "release-cleanup: 缺分支名拦截"
assert_stderr_has "缺少发布包装分支名" "release-cleanup: 缺分支名提示"

setup_release_repo
run_repo_script "$RELEASE_TMP/main" scripts/cleanup-release-branch.sh -h
assert_exit 2 "release-cleanup: -h 走 usage exit 2"

setup_release_repo
run_repo_script "$RELEASE_TMP/main" scripts/cleanup-release-branch.sh --bogus
assert_exit 2 "release-cleanup: 未知参数走 usage exit 2"

# L1b — ROOT 推导锁定：从非 git 目录用绝对路径调用带授权+白名单分支，
# BASH_SOURCE 正确解析 ROOT → 走到「本地分支不存在」校验 exit 1；
# rev-parse 在非 git cwd 赋值吞 git exit 128 → set -e 崩在 ROOT 行（exit 128，stderr 是 git fatal）。
# 本用例锁住 BASH_SOURCE 写法，防回退 rev-parse。
setup_release_repo
empty_cwd="$(mktemp -d)"; RELEASE_TMP_LIST+=("$empty_cwd")
run_repo_script "$empty_cwd" "$RELEASE_TMP/main/scripts/cleanup-release-branch.sh" --user-authorized feature/never-exists
assert_exit 1 "release-cleanup: 非 repo cwd 绝对路径调用仍解析 ROOT 走到分支校验"
assert_stderr_has "本地分支不存在" "release-cleanup: 绝对路径调用走到分支存在校验（非 rev-parse 崩）"

# L2 — 校验层（任一失败 exit 1，分支不动）
# 在 worktree 形态路径内执行 → 拦（worktree-paths.sh 把父名 blue-whale-worktrees 识别为 worktree 区）
WT_TMP="$(mktemp -d)"; RELEASE_TMP_LIST+=("$WT_TMP")
build_repo_at "$WT_TMP/blue-whale-worktrees/main" "$WT_TMP/origin.git"
run_repo_script "$WT_TMP/blue-whale-worktrees/main" scripts/cleanup-release-branch.sh --user-authorized feature/x-release
assert_exit 1 "release-cleanup: 在 worktree 内拦截"
assert_stderr_has "任务 worktree" "release-cleanup: worktree 提示"

# 当前非 master → 拦
setup_release_repo
git -C "$RELEASE_TMP/main" checkout -b feature/other >/dev/null 2>&1
run_repo_script "$RELEASE_TMP/main" scripts/cleanup-release-branch.sh --user-authorized feature/x-release
assert_exit 1 "release-cleanup: 非 master 当前分支拦截"
assert_stderr_has "切回本地 master" "release-cleanup: 非 master 提示"

# 工作区不干净 → 拦（HEAD 仍在 master，制造未跟踪文件）
setup_release_repo
echo dirty > "$RELEASE_TMP/main/dirty.txt"
run_repo_script "$RELEASE_TMP/main" scripts/cleanup-release-branch.sh --user-authorized feature/x-release
assert_exit 1 "release-cleanup: 工作区不干净拦截"
assert_stderr_has "工作区不干净" "release-cleanup: 不干净提示"

# 非白名单前缀 → 拦
setup_release_repo
run_repo_script "$RELEASE_TMP/main" scripts/cleanup-release-branch.sh --user-authorized release/x
assert_exit 1 "release-cleanup: 非白名单前缀拦截"
assert_stderr_has "白名单前缀" "release-cleanup: 白名单提示"

# L3 — 合并守卫：未合并进 origin/master → 拦且分支不删
setup_release_repo
git -C "$RELEASE_TMP/main" checkout -b feature/y-release >/dev/null 2>&1
git -C "$RELEASE_TMP/main" commit --allow-empty -m "release work" >/dev/null 2>&1
git -C "$RELEASE_TMP/main" checkout master >/dev/null 2>&1
run_repo_script "$RELEASE_TMP/main" scripts/cleanup-release-branch.sh --user-authorized feature/y-release
assert_exit 1 "release-cleanup: 未合并分支拦截"
assert_stderr_has "尚未被 origin/master 包含" "release-cleanup: 未合并提示"
if git -C "$RELEASE_TMP/main" show-ref --verify --quiet refs/heads/feature/y-release; then
  PASS=$((PASS + 1))
else
  FAIL=$((FAIL + 1)); FAILURES+=("[release-cleanup: 未合并分支应留存] feature/y-release 被误删")
fi

# L4 — 删除层：happy path（已合并 + 远程也有）→ exit 0，本地/远程双删
setup_release_repo
git -C "$RELEASE_TMP/main" checkout -b feature/x-release >/dev/null 2>&1
git -C "$RELEASE_TMP/main" commit --allow-empty -m "release content" >/dev/null 2>&1
git -C "$RELEASE_TMP/main" checkout master >/dev/null 2>&1
git -C "$RELEASE_TMP/main" merge --no-ff --no-edit feature/x-release >/dev/null 2>&1
git -C "$RELEASE_TMP/main" push -q origin master >/dev/null 2>&1
git -C "$RELEASE_TMP/main" push -q origin feature/x-release >/dev/null 2>&1
run_repo_script "$RELEASE_TMP/main" scripts/cleanup-release-branch.sh --user-authorized feature/x-release
assert_exit 0 "release-cleanup: happy path 成功"
if git -C "$RELEASE_TMP/main" show-ref --verify --quiet refs/heads/feature/x-release; then
  FAIL=$((FAIL + 1)); FAILURES+=("[release-cleanup: 本地分支应删] feature/x-release 仍存在")
else
  PASS=$((PASS + 1))
fi
if git -C "$RELEASE_TMP/main" ls-remote --exit-code --heads origin feature/x-release >/dev/null 2>&1; then
  FAIL=$((FAIL + 1)); FAILURES+=("[release-cleanup: 远程分支应删] origin feature/x-release 仍存在")
else
  PASS=$((PASS + 1))
fi

# lag：本地 master 落后 origin/master（PR 已合远端、本地未拉）→ 仍能清理。
# ADR-0010 核心：本地 master 是用户集成区，未必含 origin/master。
# 此用例锁定「用 update-ref -d 而非 branch -d」——后者在本地 master 落后时会误判未合并而拒绝。
setup_release_repo
git -C "$RELEASE_TMP/main" checkout -b feature/lag-release >/dev/null 2>&1
git -C "$RELEASE_TMP/main" commit --allow-empty -m "lagged release" >/dev/null 2>&1
git -C "$RELEASE_TMP/main" checkout master >/dev/null 2>&1
git -C "$RELEASE_TMP/main" push -q origin feature/lag-release >/dev/null 2>&1
# 模拟 PR 合并：fast-forward 推 origin/master 到该分支（本地 master 不动）
git -C "$RELEASE_TMP/main" push -q origin feature/lag-release:master >/dev/null 2>&1
git -C "$RELEASE_TMP/main" fetch -q origin >/dev/null 2>&1
run_repo_script "$RELEASE_TMP/main" scripts/cleanup-release-branch.sh --user-authorized feature/lag-release
assert_exit 0 "release-cleanup: 本地 master 落后仍能清理"
if git -C "$RELEASE_TMP/main" show-ref --verify --quiet refs/heads/feature/lag-release; then
  FAIL=$((FAIL + 1)); FAILURES+=("[release-cleanup: lag 本地分支应删] feature/lag-release 仍存在")
else
  PASS=$((PASS + 1))
fi
if git -C "$RELEASE_TMP/main" ls-remote --exit-code --heads origin feature/lag-release >/dev/null 2>&1; then
  FAIL=$((FAIL + 1)); FAILURES+=("[release-cleanup: lag 远程分支应删] origin feature/lag-release 仍存在")
else
  PASS=$((PASS + 1))
fi

# 幂等：远程源分支已不存在（他处已删 / 仅本地残留），本地仍存在 → 仍清本地且 exit 0。
# 锁定 L65 ls-remote --exit-code 返回 2（远程无）时跳过 push、不报错、本地照删。
# 本脚本相对 cleanup-task-worktree 的差异价值：远程已无时不因探活非零而失败。
setup_release_repo
git -C "$RELEASE_TMP/main" checkout -b feature/idem-release >/dev/null 2>&1
git -C "$RELEASE_TMP/main" commit --allow-empty -m "idem release" >/dev/null 2>&1
git -C "$RELEASE_TMP/main" checkout master >/dev/null 2>&1
git -C "$RELEASE_TMP/main" merge --no-ff --no-edit feature/idem-release >/dev/null 2>&1
git -C "$RELEASE_TMP/main" push -q origin master >/dev/null 2>&1
# 不 push feature/idem-release：远程无此分支，模拟「他处已删远程、本地残留」
run_repo_script "$RELEASE_TMP/main" scripts/cleanup-release-branch.sh --user-authorized feature/idem-release
assert_exit 0 "release-cleanup: 远程已无时仍清本地（幂等）"
if git -C "$RELEASE_TMP/main" show-ref --verify --quiet refs/heads/feature/idem-release; then
  FAIL=$((FAIL + 1)); FAILURES+=("[release-cleanup: 幂等本地分支应删] feature/idem-release 仍存在")
else
  PASS=$((PASS + 1))
fi

teardown_release_repos

# Slice 7 — Kimi CLI shim 路由守卫（用户级全局挂载下的跨项目隔离 + opt-in 标记）
KIMI_SHIM="$REPO_ROOT/.kimi-code/hooks/blue-whale-hook.sh"

# 参数异常一律静默放行：shim 全局挂载，任何配置错误不得波及其它项目。
run_command_hook "bash \"$KIMI_SHIM\"" '{}'
assert_exit 0 "kimi shim: 无参数静默放行"
run_command_hook "bash \"$KIMI_SHIM\" ../evil.sh" '{}'
assert_exit 0 "kimi shim: 非法 gate 名静默放行"

KIMI_SHIM_ROOT="$(mktemp -d)"

# 非 git 目录 → 静默放行
KIMI_NOGIT="$KIMI_SHIM_ROOT/nogit"
mkdir -p "$KIMI_NOGIT"
run_command_hook "(cd \"$KIMI_NOGIT\" && bash \"$KIMI_SHIM\" block-master-edit.sh)" '{}'
assert_exit 0 "kimi shim: 非 git 目录静默放行"

# git 项目缺 opt-in 标记（.kimi-code/hooks.toml）→ 静默放行（其它项目零干扰）
KIMI_OTHER="$KIMI_SHIM_ROOT/other"
mkdir -p "$KIMI_OTHER"
git -C "$KIMI_OTHER" init -q
run_command_hook "(cd \"$KIMI_OTHER\" && bash \"$KIMI_SHIM\" block-master-edit.sh)" '{}'
assert_exit 0 "kimi shim: 无 opt-in 标记的项目静默放行"

# 有标记但 Gate 缺失 → 静默放行
mkdir -p "$KIMI_OTHER/.kimi-code"
touch "$KIMI_OTHER/.kimi-code/hooks.toml"
run_command_hook "(cd \"$KIMI_OTHER\" && bash \"$KIMI_SHIM\" block-master-edit.sh)" '{}'
assert_exit 0 "kimi shim: 标记存在但 Gate 缺失静默放行"

# 标记 + Gate 齐备 → 路由执行，stdin 与 exit code/stderr 原样透传
mkdir -p "$KIMI_OTHER/.claude/hooks"
cat > "$KIMI_OTHER/.claude/hooks/block-master-edit.sh" <<'EOF'
#!/usr/bin/env bash
input="$(cat)"
case "$input" in
  *blockme*) echo "shim-gate blocked" >&2; exit 2 ;;
esac
exit 0
EOF
run_command_hook "(cd \"$KIMI_OTHER\" && bash \"$KIMI_SHIM\" block-master-edit.sh)" '{"tool_name":"Write","tool_input":{"file_path":"blockme.txt"}}'
assert_exit 2 "kimi shim: opt-in 项目路由到 Gate 并透传阻断"
assert_stderr_has "shim-gate blocked" "kimi shim: 透传 Gate 阻断原因"
run_command_hook "(cd \"$KIMI_OTHER\" && bash \"$KIMI_SHIM\" block-master-edit.sh)" '{"tool_name":"Write","tool_input":{"file_path":"ok.txt"}}'
assert_exit 0 "kimi shim: opt-in 项目 Gate 放行"

rm -rf "$KIMI_SHIM_ROOT"
unset KIMI_SHIM KIMI_SHIM_ROOT KIMI_NOGIT KIMI_OTHER

# Slice 8 — start-task-worktree.sh 主 checkout 守卫的大小写不敏感回归
# 守卫意图是「同一物理目录」，旧实现用跨来源字符串比较（git getcwd 规范大小写
# vs BASH_SOURCE/pwd 逻辑大小写），大小写不敏感 FS 上同一目录两种拼写被误拦。
# 修复后判等走 inode（samefile），对大小写与软链拼写均不敏感。
# 用例：沙箱主 checkout 建在混合大小写目录，从小写拼写路径调入口；守卫应放行，
# 由下一步「本地分支已存在」短路报错（零副作用：不 fetch、不建 Work Tree）。
# 文件系统大小写敏感（Linux）时无法构造拼写差异 → 整组跳过。
CASE_PROBE_DIR="$(mktemp -d)"
touch "$CASE_PROBE_DIR/MixedCaseProbe"
if [ -f "$CASE_PROBE_DIR/mixedcaseprobe" ]; then
  CASE_REPO_PARENT="$(mktemp -d)"
  CASE_REPO="$CASE_REPO_PARENT/CaseGuard-Repo"
  git init -q "$CASE_REPO"
  mkdir -p "$CASE_REPO/scripts/lib"
  cp "$REPO_ROOT/scripts/start-task-worktree.sh" "$CASE_REPO/scripts/"
  cp "$REPO_ROOT/scripts/start-task-worktree.py" "$CASE_REPO/scripts/"
  cp "$REPO_ROOT/scripts/lib/python3-command.sh" "$CASE_REPO/scripts/lib/"
  (
    cd "$CASE_REPO"
    git config user.email t@t
    git config user.name t
    git add scripts
    git commit -q -m "add scripts"
    git branch -M master
    git branch "fix/占位分支回归"
  )
  CASE_REPO_LOWER="$(printf '%s' "$CASE_REPO" | tr 'A-Z' 'a-z')"
  run_repo_script "$CASE_REPO_LOWER" "$CASE_REPO_LOWER/scripts/start-task-worktree.sh" --type fix --no-issue --summary 占位分支回归
  assert_exit 1 "start-entry: 小写拼写调入口不被守卫误拦"
  assert_stderr_has "本地分支已存在" "start-entry: 守卫放行后撞分支存在短路"
  rm -rf "$CASE_REPO_PARENT"
  unset CASE_REPO_PARENT CASE_REPO CASE_REPO_LOWER
else
  echo "SKIP: 文件系统大小写敏感，跳过 start-task-worktree 大小写守卫用例"
fi
rm -rf "$CASE_PROBE_DIR"
unset CASE_PROBE_DIR

# 恢复调用者环境并删除全局审计隔离仓库。
if [ -n "$ORIGINAL_CLAUDE_PROJECT_DIR" ]; then
  CLAUDE_PROJECT_DIR="$ORIGINAL_CLAUDE_PROJECT_DIR"
  export CLAUDE_PROJECT_DIR
else
  unset CLAUDE_PROJECT_DIR
fi
rm -rf "$HOOK_AUDIT_TEST_ROOT"

# ── summary ────────────────────────────────────────────────────
TOTAL=$((PASS + FAIL))
echo "────────────────────────────────────────"
printf '通过 %d / %d\n' "$PASS" "$TOTAL"
if [ "$FAIL" -gt 0 ]; then
  echo "失败用例："
  for f in "${FAILURES[@]}"; do printf '  - %s\n' "$f"; done
  exit 1
fi
echo "全 ${TOTAL} 用例通过"
exit 0
