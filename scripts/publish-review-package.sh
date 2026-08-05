#!/usr/bin/env bash
# Push a task branch for either first-time PR creation or an existing PR update.

set -euo pipefail

SCRIPT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

AUTHORIZED=0
MODE=""
MODE_COUNT=0
PR_IID=""
PR_SNAPSHOT=""
AS_JSON=0
PYTHON=()
ALLOW_SCOPE_FILES=()
. "$SCRIPT_ROOT/scripts/lib/python3-command.sh"
if select_python3_command; then
  PYTHON=("${PYTHON3_COMMAND[@]}")
fi

emit_status() {
  status="$1"
  shift
  if [ "$AS_JSON" = 1 ]; then
    if [ "${#PYTHON[@]}" -gt 0 ]; then
      "${PYTHON[@]}" - "$status" "$@" <<'PY'
import json
import sys

status, *items = sys.argv[1:]
payload = {"status": status}
for index in range(0, len(items), 2):
    key, value = items[index:index + 2]
    if key == "pull_request_id" or key.endswith("_count"):
        payload[key] = int(value)
    elif key == "changed_files":
        payload[key] = value.splitlines() if value else []
    else:
        payload[key] = value
print(json.dumps(payload, ensure_ascii=False, sort_keys=True))
PY
    else
      printf '{"status":"%s"}\n' "$status"
    fi
  else
    printf '%s' "$status"
    while [ "$#" -gt 1 ]; do
      printf ' %s=%s' "$1" "$2"
      shift 2
    done
    printf '\n'
  fi
}

fail_status() {
  code="$1"
  status="$2"
  message="$3"
  shift 3
  echo "❌ publish-review-package: $message" >&2
  emit_status "$status" "$@"
  exit "$code"
}

usage() {
  cat <<'EOF'
用法：
  scripts/publish-review-package.sh --user-authorized --create-pr [--json]
  scripts/publish-review-package.sh --user-authorized --update-pr <PR编号> --pr-snapshot <JSON文件> [--allow-scope-file <路径>] [--json]

--create-pr         首次推送并生成创建 PR 的短期发布标记
--update-pr <IID>   安全更新已有 PR 的远端源分支，不生成创建标记
--pr-snapshot FILE  Agent 通过 Gitee MCP 刚读取并规范化的 PR 快照；update 必填
--allow-scope-file  明确允许本轮审查修订新增到冻结范围的文件；可重复
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --user-authorized)
      AUTHORIZED=1
      shift
      ;;
    --create-pr)
      MODE="create"
      MODE_COUNT=$((MODE_COUNT + 1))
      shift
      ;;
    --update-pr)
      [ "$#" -ge 2 ] || fail_status 2 INVALID_PR_IID "--update-pr 缺少 PR 编号。"
      MODE="update"
      MODE_COUNT=$((MODE_COUNT + 1))
      PR_IID="$2"
      shift 2
      ;;
    --json)
      AS_JSON=1
      shift
      ;;
    --pr-snapshot)
      [ "$#" -ge 2 ] || fail_status 2 PR_SNAPSHOT_REQUIRED "--pr-snapshot 缺少文件路径。"
      PR_SNAPSHOT="$2"
      shift 2
      ;;
    --allow-scope-file)
      [ "$#" -ge 2 ] || fail_status 2 INVALID_ARGUMENT "--allow-scope-file 缺少路径。"
      ALLOW_SCOPE_FILES+=("$2")
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail_status 2 INVALID_ARGUMENT "不支持的参数：$1"
      ;;
  esac
done

[ "$AUTHORIZED" = 1 ] || fail_status 2 AUTHORIZATION_REQUIRED "缺少 --user-authorized。必须先获得用户明确授权。"
[ "$MODE_COUNT" = 1 ] || fail_status 2 INVALID_MODE "--create-pr 与 --update-pr 必须且只能选择一个。"
if [ "$MODE" = update ]; then
  case "$PR_IID" in
    ''|*[!0-9]*|0) fail_status 2 INVALID_PR_IID "PR 编号必须是正整数。" ;;
  esac
  [ -n "$PR_SNAPSHOT" ] || fail_status 2 PR_SNAPSHOT_REQUIRED "更新已有 PR 前必须通过 Gitee MCP 读取快照并传入 --pr-snapshot。"
fi

ROOT="$(git rev-parse --show-toplevel)"
# Git Bash on Windows：git rev-parse 返回 `D:/...`（大写盘符），pwd 返回 `/d/...`（小写 posix）。
# case 比较/路径拼接受影响，统一走 pwd 风格。
ROOT="$(cd "$ROOT" && pwd)"
branch="$(git -C "$ROOT" symbolic-ref --short HEAD 2>/dev/null || true)"
case "$branch" in
  feature/*|fix/*|hotfix/*|docs/*|chore/*) ;;
  "") fail_status 1 INVALID_BRANCH "当前不是分支状态。" ;;
  *) fail_status 1 INVALID_BRANCH "当前分支不是工单分支：$branch" ;;
esac

if [ -n "$(git -C "$ROOT" status --porcelain)" ]; then
  git -C "$ROOT" status --short >&2
  fail_status 1 DIRTY_WORKTREE "工作区不干净。请先提交或处理改动。"
fi

if ! fetch_detail="$(git -C "$ROOT" fetch origin master 2>&1)"; then
  fail_status 7 REMOTE_READ_FAILED "无法读取 origin/master；可按规则最多重试两次。" detail "$fetch_detail"
fi
head_sha="$(git -C "$ROOT" rev-parse HEAD)"
upstream_sha="$(git -C "$ROOT" rev-parse origin/master)"
if ! git -C "$ROOT" merge-base --is-ancestor "$upstream_sha" "$head_sha"; then
  fail_status 10 NEEDS_SYNC "当前分支落后 origin/master。Agent 应按规则运行 scripts/sync-task-from-origin.sh sync --json，完成范围化测试后重试。" branch "$branch" head "$head_sha" upstream_sha "$upstream_sha"
fi

remote_ref="refs/heads/$branch"
if ! remote_line="$(git -C "$ROOT" ls-remote --heads origin "$remote_ref" 2>&1)"; then
  fail_status 7 REMOTE_READ_FAILED "无法读取远端源分支；可按规则最多重试两次。" detail "$remote_line"
fi
remote_sha=""
if [ -n "$remote_line" ]; then
  remote_sha="${remote_line%%[[:space:]]*}"
fi

slug="$(printf '%s' "$branch" | tr '/' '%')"
common="$(git -C "$ROOT" rev-parse --git-common-dir 2>/dev/null || true)"
case "$common" in
  "") common="$ROOT/.git" ;;
  /*) ;;
  *) common="$ROOT/$common" ;;
esac
marker_path="$common/agent-release-review-package-$slug"
git_dir="$(git -C "$ROOT" rev-parse --absolute-git-dir)"
recovery_file="$git_dir/agent-sync-recovery.json"

mark_recovery_state() {
  state="$1"
  [ -f "$recovery_file" ] || return 0
  [ "${#PYTHON[@]}" -gt 0 ] || fail_status 1 PYTHON_UNAVAILABLE "同步恢复点需要可用的 Python 3；Microsoft Store 桩不可用。"
  "${PYTHON[@]}" "$SCRIPT_ROOT/scripts/sync_recovery.py" set-push-state "$recovery_file" "$head_sha" "$state"
}

clear_push_state_only_if_remote_unchanged() {
  expected_sha="$1"
  verification="$(git -C "$ROOT" ls-remote --heads origin "$remote_ref" 2>/dev/null)" || return 0
  actual_sha=""
  if [ -n "$verification" ]; then
    actual_sha="${verification%%[[:space:]]*}"
  fi
  if [ "$actual_sha" = "$expected_sha" ]; then
    mark_recovery_state clear || true
  fi
}

if [ "$MODE" = create ]; then
  if [ -n "$remote_sha" ] && ! git -C "$ROOT" merge-base --is-ancestor "$remote_sha" "$head_sha"; then
    fail_status 5 REMOTE_SOURCE_CHANGED "远端同名分支含本地未包含的提交；创建模式拒绝覆盖。" expected_remote_sha "$remote_sha" head "$head_sha"
  fi
  if ! mark_recovery_state in_flight; then
    fail_status 9 PUSH_STATE_PERSIST_FAILED "无法在推送前持久化 fail-closed 状态。"
  fi
  if ! git -C "$ROOT" push -u origin "HEAD:$remote_ref"; then
    clear_push_state_only_if_remote_unchanged "$remote_sha"
    fail_status 1 PUSH_FAILED "首次发布推送失败。"
  fi
  if ! mark_recovery_state pushed; then
    fail_status 9 PUSH_STATE_PERSIST_FAILED "远端已推送，但本地状态确认写入失败；恢复点保持 fail closed，禁止 rollback。"
  fi
  mkdir -p "$common"
  umask 077
  cat >"$marker_path" <<EOF
branch=$branch
target=master
created_at=$(date +%s)
EOF
  emit_status PUSHED_CREATE_PR branch "$branch" head "$head_sha"
  exit 0
fi

[ -n "$remote_sha" ] || fail_status 1 REMOTE_SOURCE_MISSING "更新模式要求远端已存在同名 PR 源分支。" branch "$branch" pull_request_id "$PR_IID"

expected_remote_sha="$remote_sha"
if [ -f "$recovery_file" ]; then
  [ "${#PYTHON[@]}" -gt 0 ] || fail_status 1 PYTHON_UNAVAILABLE "同步恢复点需要可用的 Python 3；Microsoft Store 桩不可用。"
  recovery_values="$("${PYTHON[@]}" - "$recovery_file" "$branch" "$head_sha" <<'PY'
import json
import sys

path, branch, head = sys.argv[1:]
data = json.load(open(path, encoding="utf-8"))
if data.get("branch") != branch or data.get("synced_head") != head:
    raise SystemExit(3)
print(data.get("remote_branch_sha", ""))
PY
)" || fail_status 1 INVALID_RECOVERY "同步恢复点与当前分支或 HEAD 不匹配。"
  expected_remote_sha="$recovery_values"
else
  if ! git -C "$ROOT" merge-base --is-ancestor "$remote_sha" "$head_sha"; then
    fail_status 5 REMOTE_SOURCE_CHANGED "本地更新未包含当前远端源分支，拒绝覆盖未知提交。" expected_remote_sha "$remote_sha" head "$head_sha"
  fi
fi

if [ "$expected_remote_sha" != "$remote_sha" ]; then
  fail_status 5 REMOTE_LEASE_CHANGED "同步快照后远端源分支已变化，停止自动更新。" expected_remote_sha "$expected_remote_sha" actual_remote_sha "$remote_sha" pull_request_id "$PR_IID"
fi

task_commit_count="$(git -C "$ROOT" rev-list --count origin/master..HEAD)"
merge_commit_count="$(git -C "$ROOT" rev-list --count --merges origin/master..HEAD)"
changed_files="$(git -C "$ROOT" diff --name-only origin/master...HEAD)"
if [ "$merge_commit_count" -gt 0 ]; then
  fail_status 6 SCOPE_MERGE_COMMIT_DETECTED "PR 创建后范围冻结；任务分支包含 merge commit，停止更新。" merge_commit_count "$merge_commit_count" task_commit_count "$task_commit_count" changed_files "$changed_files" pull_request_id "$PR_IID"
fi

[ "${#PYTHON[@]}" -gt 0 ] || fail_status 1 PYTHON_UNAVAILABLE "PR 快照硬校验需要可用的 Python 3。"
preflight=("${PYTHON[@]}" "$SCRIPT_ROOT/scripts/pr-update-evidence.py" preflight --update-pr "$PR_IID" --pr-snapshot "$PR_SNAPSHOT" --remote-sha "$remote_sha" --json)
if [ "${#ALLOW_SCOPE_FILES[@]}" -gt 0 ]; then
  for allowed_file in "${ALLOW_SCOPE_FILES[@]}"; do
    preflight+=(--allow-scope-file "$allowed_file")
  done
fi
if ! preflight_output="$("${preflight[@]}")"; then
  printf '%s\n' "$preflight_output"
  exit 8
fi

if ! mark_recovery_state in_flight; then
  fail_status 9 PUSH_STATE_PERSIST_FAILED "无法在推送前持久化 fail-closed 状态。"
fi
if ! git -C "$ROOT" push --force-with-lease="$remote_ref:$expected_remote_sha" -u origin "HEAD:$remote_ref"; then
  clear_push_state_only_if_remote_unchanged "$expected_remote_sha"
  fail_status 5 REMOTE_LEASE_CHANGED "安全强推失败；远端可能已经变化。" expected_remote_sha "$expected_remote_sha" pull_request_id "$PR_IID"
fi
if ! mark_recovery_state pushed; then
  fail_status 9 PUSH_STATE_PERSIST_FAILED "远端已推送，但本地状态确认写入失败；恢复点保持 fail closed，禁止 rollback。"
fi
rm -f "$marker_path"
emit_status PUSHED_UPDATE_PR branch "$branch" head "$head_sha" pull_request_id "$PR_IID" previous_remote_sha "$remote_sha" task_commit_count "$task_commit_count" merge_commit_count "$merge_commit_count" changed_files "$changed_files"
