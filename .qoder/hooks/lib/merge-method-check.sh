#!/usr/bin/env bash
# squash/rebase 合并方法拦截的共享逻辑。
#
# 被 confirm-release-action.sh（生产路径，三端注册）和
# block-squash-merge.sh（保留为独立可测单元）同时 source，
# 消除 Duplicated Code —— 判定 + 消息文案的唯一权威源。
#
# 为什么禁 squash/rebase：见 docs/adr/0006-sync-mechanism-auto-block.md 与
# docs/agents/commit-and-review.md「合并方法」。核心：squash/rebase 改写
# commit sha → 本地 git branch -d 误判"未合并" → 叠加 block-dangerous-git.sh
# 拦 -D → AI 无法清理本地分支（死锁）。merge 保留原 sha，-d 正常工作。
#
# 用法（source 后）：
#   check_merge_method_and_block <merge_method 值>
# 返回：squash/rebase 时打印 BLOCKED 消息到 stderr 并 exit 2；
#       merge/缺省/其他 直接 return（不 exit，交由调用方继续）。

check_merge_method_and_block() {
  local method="$1"
  case "$method" in
    squash|rebase)
      cat >&2 <<EOF
BLOCKED: PR 合并方法 ${method} 被拦截。
  merge_method: ${method}

本项目 PR 合并用 merge（非 squash/rebase）：
- squash/rebase 改写 commit sha → 本地 git branch -d 误判"未合并"
- 叠加 block-dangerous-git.sh 拦 git branch -D → 本地分支删不掉（死锁）
- merge 保留原 commit sha，git branch -d 正常工作
- 实证：master 历史 PR 全为 2-parent merge commit

改法：merge_method=merge（或不传，Gitee 默认 merge）。
详见 docs/agents/commit-and-review.md「合并方法」。
EOF
      exit 2
      ;;
  esac
}
