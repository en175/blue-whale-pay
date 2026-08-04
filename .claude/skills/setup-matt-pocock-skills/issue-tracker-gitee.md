# Issue tracker: Gitee

Issues and PRDs for this repo live in the repo's Gitee Issues. Read the remote from `git remote -v` (e.g. `git@gitee.com:<org>/<repo>.git`; web issues at `https://gitee.com/<org>/<repo>/issues`).

Gitee has no official `gh`/`glab`-equivalent CLI, so all operations go through the **Gitee MCP tools**, with the **Gitee web UI** as a manual fallback (the issues URL above) when MCP is unavailable. Two MCP variants exist:

- **Gitee Enterprise** (`mcp__gitee-ent__*`) — issues live under an enterprise (`enterprise_id`) + repo (`project_id`); the common case for private/team repos.
- **Gitee public API** (`mcp__gitee__*`) — the public-API variant; parameter names differ slightly, so check each tool's schema.

The names below are the canonical operations; verify exact arg names against each tool's live MCP schema.

## Conventions

- **Create an issue**: `create_enterprise_issue` (`enterprise_id` + `title` + `description`; multi-line bodies go straight into `description`). **You must pass `project_id` to attach the issue to this repo** — look the repo's numeric id up with `list_enterprise_repositories` (do **not** pass the `org/repo` path string; it 404s). Omitting `project_id` leaves the issue visible only in the enterprise work-item list, never on the repo's Issues page. **Labels go via `label_ids` (comma-separated numeric label ids), not `labels`** — `create_enterprise_issue` silently ignores `labels` for private repos, so follow up with an `update_enterprise_issue` carrying `label_ids`.
- **Read an issue**: `get_enterprise_issue_detail` for the issue; `list_enterprise_issue_comments` (`enterprise_id` + `issue_id`) for comments.
- **List issues**: `list_enterprise_issues`, filter by `state` (`open` / `closed` / `rejected` / `progressing`); filter by label via `label_ids` (numeric ids).
- **Comment on an issue**: `comment_enterprise_issue` (`enterprise_id` + `issue_id` + `body`).
- **Apply / remove labels**: `update_enterprise_issue` — `label_ids` is a comma-separated string of **numeric label ids** (look them up with `list_enterprise_labels`; Gitee labels must be 2–20 chars, no special characters).
- **Close**: `update_enterprise_issue` — pass **`issue_state_id`**, not `state` (`update_enterprise_issue` has no `state` param). The legal state enum depends on the issue's work-item type, so look it up first with `list_issue_type_states(enterprise_id, issue_type_id)` and pass the id mapping to "done" (e.g. 已完成); take `issue_type_id` from `get_enterprise_issue_detail`'s `issue_type.id`. After closing, the issue's `state` field reads `"closed"`.

Enterprise MCP tools locate an issue by `enterprise_id` (look it up with `list_enterprises`, matching your org's path) + `issue_id`, **not** by `owner/repo`.

## Sub-issue inheritance

To create a child issue an AFK agent can pick up, first read the parent with `get_enterprise_issue_detail(<parent ident>)`, then create the child **inheriting the parent's fields**: `parent_id = parent.id`, `project_id = parent.project_id`, `program_id = parent.program_id`, `issue_type_id = parent.issue_type.id`. Follow up with `update_enterprise_issue` to add the `ready-for-agent` `label_ids`. Then **reverse-verify** the child is repo-visible with `list_enterprise_issues(project_id = parent.project_id, search = <child ident>)`; if it does not appear, treat the publish as failed — do not hand it to an agent. (A child that shows under the parent in the enterprise console but not on the repo's Issues page was created without the repo link — recreate it inheriting `project_id`.)

## Pull requests as a triage surface

**PRs as a request surface: no.** _(Gitee repos do not currently treat external PRs as feature-request entry points. Set to `yes` and describe the MR-equivalent flow if yours does; `/triage` reads this flag.)_

Gitee uses "pull request" terminology (its Chinese UI may write 合并请求). When this flag is `yes`, external PRs run through the same labels and states as issues, using the `*_enterprise_pull` / `*_pull` MCP equivalents — `create_enterprise_repo_pull`, `get_enterprise_pull_detail`, `list_enterprise_pulls`, `comment_enterprise_pull`. Note `create_enterprise_repo_pull` also requires the **numeric `project_id`** (the path string 404s here too).

## When a skill says "publish to the issue tracker"

Create a Gitee issue (via the MCP tools above, or the web UI as fallback).

## When a skill says "fetch the relevant ticket"

Read the issue and its comments with `get_enterprise_issue_detail` + `list_enterprise_issue_comments`.

## Wayfinding operations

Used by `/wayfinder`. The **map** is a single Gitee issue with **child** issues as tickets. `/wayfinder` defines the semantics; this section only fixes their physical implementation on Gitee (enterprise MCP).

- **Label naming (Gitee forbids colons)**: `/wayfinder`'s text writes `wayfinder:map` / `wayfinder:<type>` (GitHub's colon convention). **Gitee labels do not allow colons** — use hyphens instead: the map label is `wayfinder-map`; a type label is `wayfinder-` + `<type>` → `wayfinder-research` / `wayfinder-prototype` / `wayfinder-grilling` / `wayfinder-task`. Create all five in Gitee's label management first.
- **Map**: a single Gitee issue labelled `wayfinder-map`. `create_enterprise_issue(title = <map name>, project_id = <repo id>, program_id = <optional>)`, then `update_enterprise_issue(label_ids = <wayfinder-map numeric id>)` to add the label (create silently ignores labels on private repos — see "Apply / remove labels"). Body holds Destination / Notes / Decisions-so-far / Not yet specified / Out of scope (template in `/wayfinder` SKILL.md).
- **Child ticket**: a sub-issue of the map. `create_enterprise_issue(parent_id = <map issue id>, project_id = <inherited>, program_id = <inherited>, issue_type_id = <inherited>)`, then `update_enterprise_issue(label_ids = <numeric id of the type label>)`. `<type>` ∈ research / prototype / grilling / task. Full inheritance flow under "Sub-issue inheritance".
- **Blocking**: **the Gitee MCP layer has no native issue-dependencies endpoint** — only `create_enterprise_issue` accepts `link_issue_id` (at creation time; there is no update-time equivalent), which makes a weak "related" link (UI-visible, but not blocking semantics). Per `/wayfinder`'s "fall back to a body convention only when native blocking is absent" rule → fall back: write `Blocked by: <ticket title> (<ident>)` at the top of the ticket body, one blocker per line. A ticket is **unblocked** iff every blocker issue it lists is closed — check each with `get_enterprise_issue_detail` (`state == "closed"`). To add the weak link, pass `link_issue_id=<blocker ident>` when creating the child; it is optional, a UI-visible aid only.
- **Frontier query**: `list_enterprise_issues(project_id = <map project_id>, state = "open")` to pull open issues, then filter client-side for `parent.id == <map issue id>` (list has no parent_id filter param); drop any with an `assignee` (already claimed); drop any whose body lists a not-yet-closed `Blocked by:`; first in creation order wins.
- **Claim**: `update_enterprise_issue(issue_id = <ticket>, assignee_id = <your user id>)`. Look your user id up with `list_enterprise_members`. Open and unassigned = unclaimed. **Claim before any real work** so concurrent sessions don't grab the same ticket.
- **Resolve**: ① `comment_enterprise_issue(issue_id = <ticket>, body = <answer>)` posts the resolution comment; ② `update_enterprise_issue(issue_id = <ticket>, issue_state_id = <id for "done">)` closes it (state enum via `list_issue_type_states`, see "Close"); ③ append a line to the map body's `## Decisions so far` (`- [<ticket title>](<url>) — <one-line gist>`) — `update_enterprise_issue`'s `description` is **whole-replacement, not append**, so first `get_enterprise_issue_detail(map)` for the current body, splice in the new line, then write the whole body back.
