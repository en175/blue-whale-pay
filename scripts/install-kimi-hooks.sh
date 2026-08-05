#!/usr/bin/env bash
# 安装/卸载 Blue-Whale-AI 的 Kimi CLI hooks。
#
# Kimi CLI 仅从用户级 ~/.kimi-code/config.toml 加载 hooks（实测项目级
# .kimi-code/local.toml 不加载），因此需要本安装步骤；Claude Code / Codex /
# ZCode 均为项目级配置，无需安装。
#
# 安装（幂等，可重复运行）：
#   1. 把 .kimi-code/hooks/blue-whale-hook.sh 同步到 ~/.kimi-code/hooks/
#   2. 把 .kimi-code/hooks.toml 以 managed block 形式写入 ~/.kimi-code/config.toml
#
# 卸载（--uninstall）：移除 managed block 与 shim，无残留；config.toml 其余内容不动。
#
# shim 带 opt-in 标记守卫（项目根存在 .kimi-code/hooks.toml 才路由），
# 全局挂载对其它项目零影响，见 .kimi-code/hooks/blue-whale-hook.sh 头注。
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SNIPPET="$REPO_ROOT/.kimi-code/hooks.toml"
SHIM_SRC="$REPO_ROOT/.kimi-code/hooks/blue-whale-hook.sh"

KIMI_HOME="${KIMI_CODE_HOME:-$HOME/.kimi-code}"
CONFIG="$KIMI_HOME/config.toml"
SHIM_DIR="$KIMI_HOME/hooks"
SHIM_DST="$SHIM_DIR/blue-whale-hook.sh"

BEGIN_MARK="# >>> blue-whale-ai kimi hooks (managed by scripts/install-kimi-hooks.sh) >>>"
END_MARK="# <<< blue-whale-ai kimi hooks (managed by scripts/install-kimi-hooks.sh) <<<"

usage() {
  echo "usage: install-kimi-hooks.sh [--uninstall]" >&2
  exit 2
}

[ "$#" -eq 0 ] || { [ "$#" -eq 1 ] && [ "$1" = "--uninstall" ]; } || usage

# upsert_block / remove_block：managed block 的幂等写入与移除。
# 用 python3 处理多行文本边界，避免 sed 转义陷阱。
managed_block() {
  python3 - "$CONFIG" "$BEGIN_MARK" "$END_MARK" "$SNIPPET" "$1" <<'PY'
import sys
from pathlib import Path

config_path = Path(sys.argv[1])
begin, end, snippet_path, mode = sys.argv[2], sys.argv[3], Path(sys.argv[4]), sys.argv[5]

text = config_path.read_text(encoding="utf-8") if config_path.exists() else ""
has_block = begin in text and end in text

if mode == "remove":
    if not has_block:
        print("managed block 不存在，无需移除")
        raise SystemExit(0)
    pre, rest = text.split(begin, 1)
    _, post = rest.split(end, 1)
    # 精确还原：upsert 追加时只多插入了 BEGIN 前的一个换行；
    # END 后的换行在块位于 EOF 时随块一起移除。
    if pre.endswith("\n\n"):
        pre = pre[:-1]
    if post == "\n":
        post = ""
    merged = pre + post
    if merged and not merged.endswith("\n"):
        merged += "\n"
    config_path.write_text(merged, encoding="utf-8")
    print(f"已从 {config_path} 移除 managed block")
    raise SystemExit(0)

snippet = snippet_path.read_text(encoding="utf-8").strip("\n")
block = f"{begin}\n{snippet}\n{end}\n"
if has_block:
    pre, rest = text.split(begin, 1)
    _, post = rest.split(end, 1)
    config_path.write_text(pre + block + post.lstrip("\n"), encoding="utf-8")
    print(f"已更新 {config_path} 中的 managed block")
else:
    prefix = text if (not text or text.endswith("\n")) else text + "\n"
    if prefix.strip():
        prefix += "\n"
    config_path.write_text(prefix + block, encoding="utf-8")
    print(f"已把 managed block 写入 {config_path}")
PY
}

if [ "${1:-}" = "--uninstall" ]; then
  managed_block remove
  if [ -f "$SHIM_DST" ]; then
    rm -f "$SHIM_DST"
    echo "已移除 shim: $SHIM_DST"
  fi
  echo "Kimi CLI hooks 已卸载。"
  exit 0
fi

[ -f "$SNIPPET" ] || { echo "缺少配置片段: $SNIPPET" >&2; exit 1; }
[ -f "$SHIM_SRC" ] || { echo "缺少 shim 权威源: $SHIM_SRC" >&2; exit 1; }

mkdir -p "$SHIM_DIR"
cp "$SHIM_SRC" "$SHIM_DST"
chmod +x "$SHIM_DST"
echo "已同步 shim: $SHIM_DST"

managed_block upsert

# kimi doctor 校验配置（若 kimi 在 PATH 中）。
if command -v kimi >/dev/null 2>&1; then
  kimi doctor
fi

echo "Kimi CLI hooks 安装完成；新会话生效（已有会话用 /reload 重载配置）。"
