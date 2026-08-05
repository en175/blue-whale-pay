#!/bin/bash
# CBM 代码发现增强器（PreToolUse on Grep|Glob）。
# 只注入图谱上下文，永不拦截工具调用；任何失败静默 exit 0。
# 若用户级 cbm gate 已装（owner / Sweet-Claw），让用户级处理，避免重复注入。
# 团队成员无用户级 gate，由本脚本注入。
if [ -x "$HOME/.claude/hooks/cbm-code-discovery-gate" ]; then
  exit 0
fi
BIN="$(command -v codebase-memory-mcp || true)"
[ -x "$BIN" ] || exit 0
"$BIN" hook-augment 2>/dev/null
exit 0
