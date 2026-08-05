#!/usr/bin/env bash
# gitee-resolve-ids.sh —— Gitee 企业版 ID 解析器与诊断器。
#
# 背景：Gitee 企业版 MCP（mcp__gitee-ent__*）用 enterprise_id / project_id 定位资源，
# 而这两个数字 ID 都【不出现在网页 URL 里】。URL e.gitee.com/{org}/projects/{883843}/...
# 中的 883843 是网页路由 ID，既非 enterprise_id 也非 project_id。把 URL 数字当 API ID
# 传入会触发 401「企业未授权此应用进行访问」——该错误措辞误导（实为 ID 指向的企业不存在），
# 常被误判为 OAuth 授权问题。
#
# 本脚本不发布任何请求、不依赖 token，仅做纯解析 + 校验 + 诊断：
#   resolve   —— 从人类输入（PR/issue URL 或 path）抽出 MCP 可用信息，并标注哪些需动态查
#   check-id  —— 校验给定 ID 值是否是「URL 抄来的危险值」
#   diagnose-401 —— 打印 401 诊断决策树（ID 错 vs token 错 vs 真未授权）
#
# 设计哲学（同 start-task-worktree.sh）：把易错操作收口，让人/Agent【不必手抄 ID】。
# 详见 docs/agents/issue-tracker.md「ID 解析约定」。

set -euo pipefail

fail() { echo "❌ gitee-resolve-ids: $*" >&2; exit 1; }

usage() {
  cat <<'EOF'
用法：
  gitee-resolve-ids.sh resolve  <PR_URL | ISSUE_URL | path-with-namespace>
  gitee-resolve-ids.sh check-id <enterprise_id|project_id> <值>
  gitee-resolve-ids.sh diagnose-401

resolve 示例：
  gitee-resolve-ids.sh resolve "https://e.gitee.com/hangzhou-xuanfu_1/projects/883843/repos/hangzhou-xuanfu_1/blue-whale-ai/pulls/93"
  gitee-resolve-ids.sh resolve "hangzhou-xuanfu_1/blue-whale-ai"
  gitee-resolve-ids.sh resolve "https://gitee.com/hangzhou-xuanfu_1/blue-whale-ai/pulls/93"

check-id 示例：
  gitee-resolve-ids.sh check-id enterprise_id 883843
  gitee-resolve-ids.sh check-id project_id 48854568
EOF
}

# ─── resolve ──────────────────────────────────────────────────────────────
# 从输入抽出：企业 path、仓库 path-with-namespace、资源类型(pull/issue)及编号。
# URL 里【唯一可信】的是 path 段（hangzhou-xuanfu_1、blue-whale-ai）和 pulls/issues 的编号；
# projects/ 后的数字（如 883843）是网页路由 ID，不可用作 API ID。
do_resolve() {
  local input="$1"
  local enterprise_path="" repo_path="" res_kind="" res_number="" url_route_id=""

  # 抽 path-with-namespace：支持
  #   - 完整 URL（e.gitee.com 或 gitee.com，含或不含 /projects/NNNN/repos/ 段）
  #   - 裸 path-with-namespace（org/repo）
  # 策略：剥协议与主机，按已知结构分段识别。
  local stripped="${input#*://}"          # 去 scheme（无 scheme 时原样）
  stripped="${stripped#*gitee.com/}"       # 去主机（无主机时原样）
  stripped="${stripped#*e.gitee.com/}"
  stripped="${stripped#/}"                 # 去前导斜杠

  # 企业版 URL 形如：{org}/projects/{NNNN}/repos/{org}/{repo}/pulls/{n}
  # 普通版 URL 形如：{org}/{repo}/pulls/{n}
  # 先尝试企业版结构
  if [[ "$stripped" =~ ^([^/]+)/projects/([0-9]+)/repos/([^/]+)/([^/]+)/(.*)$ ]]; then
    enterprise_path="${BASH_REMATCH[1]}"
    url_route_id="${BASH_REMATCH[2]}"        # 网页路由 ID —— 陷阱
    repo_path="${BASH_REMATCH[3]}/${BASH_REMATCH[4]}"
    local tail="${BASH_REMATCH[5]}"
    case "$tail" in
      pulls/*)   res_kind="pull";  res_number="${tail#pulls/}"   ;;
      issues/*)  res_kind="issue"; res_number="${tail#issues/}"  ;;
    esac
  elif [[ "$stripped" =~ ^([^/]+)/([^/]+)/(pulls|issues)/([A-Za-z0-9]+) ]]; then
    # 普通版 URL：org/repo/(pulls|issues)/n 或 issues/IDENT（Gitee issue 是字符串 ident）
    enterprise_path="${BASH_REMATCH[1]}"
    repo_path="${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
    [[ "${BASH_REMATCH[3]}" == "pulls" ]] && res_kind="pull" || res_kind="issue"
    res_number="${BASH_REMATCH[4]}"
  elif [[ "$stripped" =~ ^([^/]+)/([^/]+)$ ]]; then
    # 裸 path-with-namespace
    enterprise_path="${BASH_REMATCH[1]}"
    repo_path="${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
  else
    fail "无法解析输入：$input
预期形式之一：
  - 企业版 URL：https://e.gitee.com/{org}/projects/{NNNN}/repos/{org}/{repo}/pulls/{n}
  - 普通版 URL：https://gitee.com/{org}/{repo}/pulls/{n}
  - 裸 path：{org}/{repo}"
  fi

  # 基本校验
  [[ -n "$enterprise_path" ]] || fail "未能抽出企业 path。"
  [[ -n "$repo_path" ]] || fail "未能抽出仓库 path-with-namespace。"

  echo "解析结果："
  echo "  输入                  : $input"
  echo "  企业 path            : $enterprise_path"
  echo "  仓库 path-with-ns    : $repo_path"
  if [[ -n "$res_kind" ]]; then
    echo "  资源                  : ${res_kind} #${res_number}"
  fi
  echo ""
  echo "── 可直接执行的 MCP 查询（动态解析 API ID） ──"
  echo "  enterprise_id = list_enterprises()  → 取 path=\"$enterprise_path\" 的 id"
  echo "  project_id    = list_enterprise_repositories(enterprise_id, search=\"$(basename "$repo_path")\")"
  echo "                   → 取 path_with_namespace=\"$repo_path\" 的 id"
  echo ""
  if [[ -n "$res_kind" ]]; then
    echo "── 可直接调用的 MCP 工具（填入上面查到的两个 id） ──"
    if [[ "$res_kind" == "pull" ]]; then
      echo "  get_enterprise_pull_detail(enterprise_id=<上查>, project_id=<上查>, pull_request_id=$res_number)"
      echo "  comment_enterprise_pull(enterprise_id=<上查>, project_id=<上查>, pull_request_id=$res_number, body=\"...\")"
    else
      echo "  get_enterprise_issue_detail(enterprise_id=<上查>, issue_id=\"$res_number\")"
      echo "  comment_enterprise_issue(enterprise_id=<上查>, issue_id=\"$res_number\", body=\"...\")"
    fi
    echo ""
    echo "  注：pull_request_id / issue 编号是 URL 里【唯一可直接抄】的数字。"
  fi

  # 关键告警：URL 路由 ID
  if [[ -n "$url_route_id" ]]; then
    echo ""
    echo "⚠️  URL 中 projects/$url_route_id 的 $url_route_id 是网页路由 ID。"
    echo "   它【不是】enterprise_id，也【不是】project_id——切勿直接传给任何 mcp__gitee-ent__* 工具。"
    echo "   （误传会触发 401「企业未授权此应用进行访问」，实为 ID 指向的企业不存在，非授权问题）"
  fi
}

# ─── check-id ─────────────────────────────────────────────────────────────
# 离线校验一个 ID 值。脚本不发请求，所以【不能】判定一个值「正确」，只能识别
# 「已知危险」（URL 路由 ID）。任何不在危险清单里的值都标「无法离线确认」，
# 唯一权威来源始终是动态查询。这样避免对正确值误报，也避免对未知值打包票。
#
# 已知 URL 路由 ID 清单：累积本仓踩过的陷阱值。新增陷阱时在此追加。
KNOWN_URL_ROUTE_IDS=(
  "883843"   # 曾被误当 enterprise_id，实为 e.gitee.com projects/ 段网页路由 ID
)

do_check_id() {
  local which="$1" value="$2"
  [[ "$which" == "enterprise_id" || "$which" == "project_id" ]] \
    || fail "第一个参数必须是 enterprise_id 或 project_id，收到：$which"
  [[ "$value" =~ ^[0-9]+$ ]] || fail "$which 的值应为纯数字，收到：$value"

  echo "校验：$which = $value"
  echo ""

  # 1) 已知危险值：精确匹配陷阱清单
  local is_known_route=0
  for bad in "${KNOWN_URL_ROUTE_IDS[@]}"; do
    [[ "$value" == "$bad" ]] && { is_known_route=1; break; }
  done
  if [[ "$is_known_route" == 1 ]]; then
    echo "🚨 已知危险：$value 在本仓 URL 路由 ID 清单中（e.gitee.com projects/ 段网页路由 ID）。"
    echo "   它【不是】enterprise_id 也【不是】project_id。传给任何 mcp__gitee-ent__* 工具"
    echo "   会触发误导性 401「企业未授权此应用进行访问」（实为企业不存在，非授权问题）。"
    echo ""
    echo "   → 用下面的动态查询换掉它。"
  else
    echo "ⓘ 无法离线确认 ${value} 是否为正确的 ${which}。"
    echo "   脚本不发请求，唯一权威来源是下面的动态查询。请实查核对，勿依赖本结果下结论。"
  fi
  echo ""

  # 2) 正确做法指引
  if [[ "$which" == "enterprise_id" ]]; then
    echo "✔ 正确做法：list_enterprises() → 取 path==\"hangzhou-xuanfu_1\" 的 id。"
    echo "  enterprise_id 不出现在任何网页 URL 中。"
  else
    echo "✔ 正确做法：list_enterprise_repositories(enterprise_id, search=\"blue-whale-ai\")"
    echo "            → 取 path_with_namespace==\"hangzhou-xuanfu_1/blue-whale-ai\" 的 id。"
    echo "  project_id 不出现在任何网页 URL 中。"
  fi
  echo ""
  echo "  401 自检：调 get_user_info()"
  echo "    - 成功 → token 有效；若用此 $value 调用仍 401，则值是错的 ID，非授权问题。"
  echo "    - 401  → token/授权问题，与 ID 无关。"
}

# ─── diagnose-401 ─────────────────────────────────────────────────────────
# 打印 401 决策树，翻译 Gitee 误导性措辞。
do_diagnose_401() {
  cat <<'EOF'
401「企业未授权此应用进行访问」诊断决策树
==========================================

Gitee 这条信息把三种性质不同的情况混为一谈，按下面顺序排查：

步骤 1 —— 判 token 是否有效
  调 get_user_info()
    ├─ 成功返回用户 → token 有效，进入步骤 2
    └─ 401          → token 失效或类型不符，进入步骤 3

步骤 2 —— token 有效仍 401 = ID 错（最常见，非授权问题！）
  调 list_enterprises() → 看返回里 path=="hangzhou-xuanfu_1" 的真实 id。
  你传的 enterprise_id 若与之不同，就是错的。
  最典型成因：把网页 URL projects/ 后的数字（网页路由 ID）当成了 enterprise_id。
  → 解法：用 list_enterprises / list_enterprise_repositories 动态查正确 ID，
         或先跑 gitee-resolve-ids.sh resolve <URL> 得到查询指引。

步骤 3 —— token 失效
  - 普通版 REST（/api/v5）报「Access token is wrong type」
    → 该 token 是企业版 MCP 专用，不能调普通 API；用 MCP 工具而非 curl。
  - MCP 工具也 401
    → token 过期或被吊销，重新生成。

黄金法则：enterprise_id / project_id 永远动态查，永不从网页 URL 抄。
EOF
}

# ─── 入口 ──────────────────────────────────────────────────────────────────
[[ $# -ge 1 ]] || { usage; exit 1; }
cmd="$1"; shift
case "$cmd" in
  resolve)       [[ $# -eq 1 ]] || { usage; exit 1; }; do_resolve "$1" ;;
  check-id)      [[ $# -eq 2 ]] || { usage; exit 1; }; do_check_id "$1" "$2" ;;
  diagnose-401)  do_diagnose_401 ;;
  -h|--help|help) usage ;;
  *) fail "未知命令：$cmd（应为 resolve | check-id | diagnose-401）" ;;
esac
