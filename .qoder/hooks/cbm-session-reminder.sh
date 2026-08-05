#!/bin/bash
# SessionStart hook: CBM FIRST 代码发现协议（精简版，对全员生效）。
# 若用户级 cbm-session-reminder 已装，让用户级处理，避免重复注入。
if [ -x "$HOME/.claude/hooks/cbm-session-reminder" ]; then
  exit 0
fi
cat << 'REMINDER'
CRITICAL - 代码发现协议（CBM 第一站）:
（未装 CBM 可直接用 Grep/Glob/Read，onboarding 见 docs/agents/code-intelligence.md）
1. 代码探索先用 codebase-memory-mcp（CBM）工具：
   - search_graph(name_pattern/label/qn_pattern) 找函数/类/路由
   - trace_path(function_name, mode=calls|data_flow|cross_service) 查调用链
   - get_code_snippet(qualified_name) 取精确符号源码
   - query_graph(query) 复杂 Cypher 模式
   - get_architecture(aspects) 项目结构全景
   - search_code(pattern) 文本搜索（图谱增强 grep）
2. 文本/配置/非代码文件自由用 Grep/Glob/Read；改文件前必先 Read。
3. 项目未索引先 index_repository。
4. graphify 用于可视化/跨文档/自然语言深挖（按需进阶，非默认第一站）。

CBM 未装？见 docs/agents/code-intelligence.md「团队 onboarding」。
REMINDER
