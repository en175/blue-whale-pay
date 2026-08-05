#!/usr/bin/env bash
# AI Agent internal entrypoint for granting and revoking scoped remote-action authorization.

set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AUTH_HELPER="$ROOT/.claude/hooks/lib/authorization.py"

fail() {
  echo "❌ manage-agent-authorization: $*" >&2
  exit 2
}

usage() {
  cat >&2 <<'EOF'
用法：
  scripts/manage-agent-authorization.sh grant --user-authorized merge-pr --enterprise-id <id> --project-id <id> --pull-request-id <id>
  scripts/manage-agent-authorization.sh grant --user-authorized create-release --enterprise-id <id> --project-id <id> --release-tag-version <tag>
  scripts/manage-agent-authorization.sh revoke merge-pr --enterprise-id <id> --project-id <id> --pull-request-id <id>
  scripts/manage-agent-authorization.sh revoke create-release --enterprise-id <id> --project-id <id> --release-tag-version <tag>
  scripts/manage-agent-authorization.sh revoke --all

本入口由 AI Agent 在当前对话已获得明确人类授权后自动调用；人类无需记忆或管理凭证。
EOF
  exit 2
}

[ "$#" -ge 1 ] || usage
MODE="$1"
shift

case "$MODE" in
  grant|revoke) ;;
  *) fail "操作必须是 grant 或 revoke。" ;;
esac

if [ "$MODE" = revoke ] && [ "${1:-}" = --all ]; then
  [ "$#" -eq 1 ] || usage
  exec python3 "$AUTH_HELPER" revoke-all "$ROOT"
fi

AUTHORIZED=0
ACTION=""
ENTERPRISE_ID=""
PROJECT_ID=""
SUBJECT=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --user-authorized)
      AUTHORIZED=1
      shift
      ;;
    merge-pr|create-release)
      [ -z "$ACTION" ] || usage
      ACTION="$1"
      shift
      ;;
    --enterprise-id)
      [ "$#" -ge 2 ] || usage
      ENTERPRISE_ID="$2"
      shift 2
      ;;
    --project-id)
      [ "$#" -ge 2 ] || usage
      PROJECT_ID="$2"
      shift 2
      ;;
    --pull-request-id)
      [ "$#" -ge 2 ] || usage
      [ "$ACTION" = merge-pr ] || fail "--pull-request-id 仅适用于 merge-pr。"
      SUBJECT="$2"
      shift 2
      ;;
    --release-tag-version)
      [ "$#" -ge 2 ] || usage
      [ "$ACTION" = create-release ] || fail "--release-tag-version 仅适用于 create-release。"
      SUBJECT="$2"
      shift 2
      ;;
    *)
      fail "不支持的参数：$1"
      ;;
  esac
done

[ -n "$ACTION" ] || fail "缺少动作：merge-pr 或 create-release。"
[ -n "$ENTERPRISE_ID" ] || fail "缺少 --enterprise-id。"
[ -n "$PROJECT_ID" ] || fail "缺少 --project-id。"
[ -n "$SUBJECT" ] || fail "缺少操作对象。"

case "$ENTERPRISE_ID" in *[!0-9]*|"") fail "enterprise-id 必须是数字。" ;; esac
case "$PROJECT_ID" in *[!0-9]*|"") fail "project-id 必须是数字。" ;; esac
if [ "$ACTION" = merge-pr ]; then
  case "$SUBJECT" in *[!0-9]*|"") fail "pull-request-id 必须是数字。" ;; esac
fi

if [ "$MODE" = grant ] && [ "$AUTHORIZED" != 1 ]; then
  fail "缺少 --user-authorized。AI 必须先从当前对话获得明确人类授权。"
fi

if [ "$MODE" = grant ]; then
  exec python3 "$AUTH_HELPER" grant --user-authorized "$ROOT" "$ACTION" "$ENTERPRISE_ID" "$PROJECT_ID" "$SUBJECT"
fi
exec python3 "$AUTH_HELPER" "$MODE" "$ROOT" "$ACTION" "$ENTERPRISE_ID" "$PROJECT_ID" "$SUBJECT"
