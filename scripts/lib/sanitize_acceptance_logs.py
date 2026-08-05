#!/usr/bin/env python3
"""验收失败取证日志脱敏器（IK1NS2）。

全栈验收失败时会采集 Compose 服务日志作为诊断证据。落盘前必须脱敏：
不出现凭据、Token、原始敏感内容或内部异常细节（堆栈帧）；
异常标题行与普通诊断行原样保留，保证仍能定位问题。

用法：
    docker compose ... logs --no-color <svc> | python3 scripts/lib/sanitize_acceptance_logs.py > <svc>.log
"""

import re
import sys

# JWT：三段 base64url，以 eyJ 开头（JSON header {"alg"...} 的固定前缀）。
_JWT_RE = re.compile(r"eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}")

# Authorization: Bearer <token>
_BEARER_RE = re.compile(r"(?i)(bearer\s+)[A-Za-z0-9._~+/=-]+")

# key=value / "key": "value" 形式的敏感键值。键名保留以便定位，值替换。
# 键名允许大写/下划线前后缀（MYSQL_PASSWORD、JWT_SECRET、OPENAI_API_KEY 等）。
_SECRET_KV_RE = re.compile(
    r"(?i)\b([A-Za-z0-9_]*(?:"
    r"password|passwd|secret|token"
    r"|access_?key|secret_?key|api_?key"
    r")[A-Za-z0-9_]*)(\s*[\"\']?\s*[:=]\s*[\"\']?)"
    r"([^\s,\"\'}\]]+)"
)

# Java/Python 堆栈帧行（可带 docker compose 日志的「容器名 | 」前缀）。
_STACK_FRAME_RE = re.compile(
    r"^(?:\S+\s*\|\s*)?\s*at\s+[\w.$_]+\.[\w$<>]+\([^)]*\)\s*$"
)
_FRAMES_OMITTED_RE = re.compile(
    r"^(?:\S+\s*\|\s*)?\s*\.\.\.\s+\d+\s+(?:more|common frames omitted)\s*$"
)

_REDACTED = "[REDACTED]"
_REDACTED_JWT = "[REDACTED_JWT]"


def sanitize_text(text: str) -> str:
    """返回脱敏后的文本。键名、异常标题与普通日志内容保留；敏感值与堆栈帧剔除。"""
    text = _JWT_RE.sub(_REDACTED_JWT, text)
    text = _BEARER_RE.sub(r"\1" + _REDACTED, text)
    text = _SECRET_KV_RE.sub(lambda m: m.group(1) + m.group(2) + _REDACTED, text)
    lines = [
        line
        for line in text.splitlines(keepends=True)
        if not _STACK_FRAME_RE.match(line) and not _FRAMES_OMITTED_RE.match(line)
    ]
    return "".join(lines)


def main() -> int:
    sys.stdout.write(sanitize_text(sys.stdin.read()))
    return 0


if __name__ == "__main__":
    sys.exit(main())
