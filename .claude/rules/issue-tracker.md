# Gitee Issue 与 MCP 工具

> **正文格式保护：** MCP 读取的 Markdown／HTML 不代表编辑模式；富文本正文不得用普通 `description` 整体写回。正文变更遵守共同 SOP 的“Gitee 富文本保护”，使用保留格式的编辑入口，保存后重进编辑态核验图表。改其他字段不带正文。

Issues 追踪在 Gitee 仓库 `git@gitee.com:hangzhou-xuanfu_1/blue-whale-pay.git`。产研协作规则：`docs/agents/bluewhale-product-sop.md`

> ⚠️ **所有 `mcp__gitee-ent__*` 调用**：`enterprise_id` / `project_id` / `program_id` 的兜底值见 CLAUDE.md「Gitee ID 兜底常量」（日常直接用）。**永不从网页 URL 抄**——URL 的 `883843` 是 program_id，误当 `enterprise_id` / `project_id` 传入会触发误导性 401。疑似变更或 401 时，用 `list` API 动态查 + `scripts/gitee-resolve-ids.sh resolve <URL>` 校验。详见 `docs/agents/issue-tracker.md`「ID 解析约定」。

## 写操作回读验证（防静默忽略）

`mcp__gitee-ent__*` 写工具对未知/错名参数**静默忽略**、不报错。已踩坑：创建 issue 把描述传到 `body`（正确参数名 `description`），建成空描述工单（IK5THP）。

- **任何写调用后必须回读验证关键字段已生效**：创建 issue 后 `get_enterprise_issue_detail` 确认 `description` 非空、标签已上；创建 PR / Release 后同样回读确认标题、描述、目标分支。
- 入参名以工具 schema 为准，不凭印象。同族已知静默陷阱：`create` 的 `labels`（见「创建 Issue」）。

## 创建 Issue

- `mcp__gitee-ent__create_enterprise_issue` — **必传 `project_id`**（值用 `list_enterprise_repositories` 查），否则工单只在企业工作项可见、仓库 Issues 页看不到。
- `create` 对企业私有仓库的 `labels` 会静默忽略 → 紧跟 `update_enterprise_issue` 补 `label_ids`。

## 创建 PR

- `mcp__gitee-ent__create_enterprise_repo_pull` — **必传数字 `project_id`**（值用 `list_enterprise_repositories` 查）。工具描述写「Project ID or PathWithNamespace」，**实际传 PathWithNamespace（如 `hangzhou-xuanfu_1/blue-whale-pay`）会 404「仓库不存在」**，勿被误导。
- 查询方式：`list_enterprise_repositories(enterprise_id, search=...)` → 取返回结果中的数字 `id`。

## 子 Issue

- 创建前先读父项，继承 `project_id` / `program_id`。
- 创建后用 `list_enterprise_issues(project_id, search=ident)` 反查，确保 AI Agent 能从仓库 Issues 拉到任务。
- 见 `docs/adr/0008`

## 标签

- `mcp__gitee-ent__update_enterprise_issue` — `label_ids` 为逗号分隔的**标签数字 ID**（非名称），ID 用 `list_enterprise_labels` 查。
- 长度 2–20，非特殊字符。
- Triage 五标签：needs-triage / needs-info / ready-for-agent / ready-for-human / wontfix。详见 `docs/agents/triage-labels.md`

## 任务状态与真实交付

按 [蓝鲸产研协作规则](../../docs/agents/bluewhale-product-sop.md) 执行。先核对 PRD 评审和产品确认，再开始受影响的业务代码修改；建 worktree、提交或合并 PR 本身均不构成评审、验收或上线证据。

| 节点 | 状态与责任 |
| --- | --- |
| 开始执行 | 需求／任务进入开发中，缺陷进入修复中；须已具备规格、认领和当前操作授权 |
| 提交、创建或合并 PR | 不自动置完成态；按仓库约定更新审查标签，不能代替部署与验收 |
| 实际候选部署到测试环境 | 有部署证据后可按授权提测，进入测试-待测试 |
| 测试及发布前验收通过 | 测试确认后进入待发布；随父需求一起测的子任务也必须有对应测试结论 |
| 实际部署生产 | 按授权进入生产-待验证；部署不等于验收 |
| 生产验证与测试、产品共同验收通过 | 两环境验证均通过后，依角色权限进入已上线；不能代签验收 |
| 不通过或放弃 | 测试／生产相应打回，研发接回开发中／修复中后重新验证；已关闭用于放弃等终止情形 |

- 纯文档、调研及测试专项按实际交付目标处理，不虚构部署。子任务交付不自动完成父需求。
- 读细状态 `issue_state.title`，不可仅按粗状态 `state` 判断。写前用 `list_issue_type_states` 查询当前类型的合法 ID，不沿用退役的「已完成／已修复／已验收」状态 ID。
- 已有其他人在做、处于测试／待发布／生产待验证或已终止时，先确认接手或返工范围，不自动抢占或重开。
- 状态、标签、评论均须处于当前用户授权范围；测试结论、共同验收、优先级和发布放行由相应负责人确认。只读任务及 `--no-issue` 任务不自动流转工单。
- 改状态不带 `description`；补标签先读现有列表再合并写回。写后回读；失败先确认实际状态再决定是否重试，不盲目重复提交，未同步如实报告。

## 关闭 Issue

- `mcp__gitee-ent__update_enterprise_issue` — 用 `issue_state_id`，**不是 `state`**（该工具无此参数）。
- 先 `list_issue_type_states` 查合法状态枚举；按实际交付和验收选择状态，已关闭只用于终止，不因 PR 合并自动完成。

## 合并 PR

- `mcp__gitee-ent__merge_enterprise_pull` — `merge_method=merge`（或不传）。
- **无 `prune_source_branch` 参数**，Gitee merge 默认不删源分支。事后跑 `scripts/cleanup-task-worktree.sh`。
- 踩坑记录：`docs/agents/hooks/README.md`
