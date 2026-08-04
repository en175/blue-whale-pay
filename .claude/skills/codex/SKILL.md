---
name: codex
description: Delegate code review or implementation tasks to the local Codex CLI (GPT-5.x, ChatGPT-authenticated, shares this repo). Use for a second opinion, an adversarial review, or to hand off a self-contained task. Triggers: "ask codex", "codex review", "delegate to codex", "second opinion", "让 codex 看看", "codex 审查".
---

# Codex

Delegate work to the local Codex CLI — a separate agent (GPT-5.x) that shares this repository checkout and git state. Use it as a second opinion, an adversarial reviewer, or to parallelize a self-contained task.

> **In Claude Code**: prefer the official `/codex:review`, `/codex:adversarial-review`, `/codex:rescue` commands (from the `codex@openai-codex` plugin) — they wrap this CLI with job tracking. This skill is the **portable** version for ZCode / Kimi Code / plain shell.

## Prerequisites (already configured in this project)
- `codex` CLI installed + ChatGPT-authenticated. Verify: `codex login status`.
- Runs in the current working directory — Codex sees the same files and git state you do.

## Core commands

### Delegate a task (non-interactive)
```bash
codex exec "<task description>"
```
Default sandbox is **read-only** — Codex investigates and answers but writes nothing.

To let Codex modify files:
```bash
codex exec -s workspace-write "<task description>"
```
Always review the diff before keeping (`git diff`).

### Code review
```bash
codex review                       # review uncommitted changes
codex review --base master         # review this branch vs master
codex review "focus on race conditions in auth"   # steerable focus text
```

### Resume a previous Codex session
```bash
codex exec resume --last
```

## When to delegate vs do it yourself
- **Delegate**: adversarial challenge to your plan; a second opinion on a tricky bug; a self-contained task worth parallelizing.
- **Don't**: trivial edits; anything needing context Codex lacks; when the round-trip cost isn't worth it.

## Prompting Codex (it has none of your context)
- State the goal, constraints, and definition of done explicitly.
- Reference files by relative path (same repo).
- Prefer read-only first; escalate to `workspace-write` only when you intend Codex to edit and you're ready to review the diff.

## Output & safety
- Summarize `codex exec` output for the user; don't dump raw bytes unless asked.
- Long tasks → run in the background, check the result later.
- `read-only` is the safe default. Never use `danger-full-access` without explicit user authorization.

## Deeper integration (optional)
- `codex mcp-server` — run Codex as an MCP server (stdio); MCP-aware clients (e.g. Kimi Code) can then call Codex as a tool.
- `codex` with no subcommand — interactive TUI.
