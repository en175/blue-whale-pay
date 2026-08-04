# Gitee Issue 与 MCP 工具

Issues 追踪在 Gitee 仓库 `git@gitee.com:hangzhou_xuanfu_1/blue-whale-ai.git`。详细流程：`docs/agents/issue-tracker.md`

> ⚠️ **所有 `mcp__gitee-ent__*` 调用**：`enterprise_id` / `project_id` / `program_id` 的兜底值见 CLAUDE.md「Gitee ID 兜底常量」（日常直接用）。**永不从网页 URL 抄**——URL 的 `883843` 是 program_id，误当 `enterprise_id` / `project_id` 传入会触发误导性 401。疑似变更或 401 时，用 `list` API 动态查 + `scripts/gitee-resolve-ids.sh resolve <URL>` 校验。详见 `docs/agents/issue-tracker.md`「ID 解析约定」。

## 写操作回读验证（防静默忽略）

`mcp__gitee-ent__*` 写工具对未知/错名参数**静默忽略**、不报错。已踩坑：创建 issue 把描述传到 `body`（正确参数名 `description`），建成空描述工单（IK5THP）。

- **任何写调用后必须回读验证关键字段已生效**：创建 issue 后 `get_enterprise_issue_detail` 确认 `description` 非空、标签已上；创建 PR / Release 后同样回读确认标题、描述、目标分支。
- 入参名以工具 schema 为准，不凭印象。同族已知静默陷阱：`create` 的 `labels`（见「创建 Issue」）。

## 创建 Issue

- `mcp__gitee-ent__create_enterprise_issue` — **必传 `project_id`**（值用 `list_enterprise_repositories` 查），否则工单只在企业工作项可见、仓库 Issues 页看不到。
- `create` 对企业私有仓库的 `labels` 会静默忽略 → 紧跟 `update_enterprise_issue` 补 `label_ids`。

## 创建 PR

- `mcp__gitee-ent__create_enterprise_repo_pull` — **必传数字 `project_id`**（值用 `list_enterprise_repositories` 查）。工具描述写「Project ID or PathWithNamespace」，**实际传 PathWithNamespace（如 `hangzhou_xuanfu_1/blue-whale-ai`）会 404「仓库不存在」**，勿被误导。
- 查询方式：`list_enterprise_repositories(enterprise_id, search=...)` → 取返回结果中的数字 `id`。

## 子 Issue

- 创建前先读父项，继承 `project_id` / `program_id`。
- 创建后用 `list_enterprise_issues(project_id, search=ident)` 反查，确保 AI Agent 能从仓库 Issues 拉到任务。
- 见 `docs/adr/0008`

## 标签

- `mcp__gitee-ent__update_enterprise_issue` — `label_ids` 为逗号分隔的**标签数字 ID**（非名称），ID 用 `list_enterprise_labels` 查。
- 长度 2–20，非特殊字符。
- Triage 五标签：needs-triage / needs-info / ready-for-agent / ready-for-human / wontfix。详见 `docs/agents/triage-labels.md`

## 任务状态机（Agent 全自动流转）

看板状态必须实时反映真实进度。以下流转由 Agent 在触发点主动执行，不等人手动改。

### 状态白名单（仅此这些流转，状态 id 为本仓实测值）

| 触发点 | 类型 | 流转 |
| --- | --- | --- |
| worktree 入口成功且带 `--issue` | 需求 | 意向(4336301) → 进行中(4336298) |
| 同上 | 任务 | 待办的(4336297) → 进行中(4336298) |
| 同上 | 缺陷 | 待确认(4336303)/已确认(4336304) → 修复中(4336305) |
| PR 创建成功 | 全部 | 打 `ready-for-review` 标签(id 344268623) |
| PR 合并成功 | 需求/任务 | → 已完成(4336299) |
| PR 合并成功 | 缺陷 | → 已修复(4336306)，另打 `修复待验证` 标签(id 344168629) |

- **禁止 Agent 设置**：已验收(4336307)、已拒绝(4336302)、已取消(4336300) —— 归人操作。
- 只读任务（调研/答疑/评审，不建 worktree）不触发状态流转；`--no-issue` 任务无状态可改。

### 开工流转（worktree 入口成功后立即执行）

1. `get_enterprise_issue_detail` 查当前状态。
2. 前置状态判定：
   - 预期起点（需求=意向、任务=待办的、缺陷=待确认/已确认）→ 调 `update_enterprise_issue(issue_state_id=<目标>)` 流转。缺陷在「待确认」也直接跳「修复中」（认领即确认），不走「已确认」中间步。
   - 已是「进行中」→ **停止**，向用户报告并等待指示（可能他人/另一会话在做）。
   - 已是终态（已完成/已取消/已拒绝）→ **停止**，向用户报告并等待指示（防重复做已完成任务）。
3. 状态 id 疑似失效（报错）时按 `list_issue_type_states(enterprise_id, issue_type_id)` 重查，不得凭本表死磕。

### 完成流转（PR 合并成功后执行）

- 按白名单表置完成态；缺陷另打 `修复待验证`。
- 补标签时 `label_ids` 是整体语义：先 `get_enterprise_issue_detail` 取现有标签，合并后整体写回，不得只传新标签覆盖掉旧标签。

### 失败处理

- 状态/标签变更失败：重试一次。
- 仍失败：继续主线工作不阻塞，但最终汇报必须置顶标红「⚠️ 工单状态未同步」，附手动指引（工单号 + 目标状态名 + 状态 id）。
- 幂等：工单已在目标状态视为成功，直接跳过。

## 关闭 Issue

- `mcp__gitee-ent__update_enterprise_issue` — 用 `issue_state_id`，**不是 `state`**（该工具无此参数）。
- 先 `list_issue_type_states` 查合法状态枚举，传「已完成」对应的 id。

## 合并 PR

- `mcp__gitee-ent__merge_enterprise_pull` — `merge_method=merge`（或不传）。
- **无 `prune_source_branch` 参数**，Gitee merge 默认不删源分支。事后跑 `scripts/cleanup-task-worktree.sh`。
- 踩坑记录：`docs/agents/hooks/README.md`
