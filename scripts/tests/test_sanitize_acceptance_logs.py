#!/usr/bin/env python3
"""Unit tests for scripts/lib/sanitize_acceptance_logs.py (IK1NS2).

验收失败取证日志必须先脱敏再落盘：不得包含凭据、Token 或原始敏感内容，
同时保留足以定位问题的普通诊断信息。公开 seam：
- sanitize_text(text: str) -> str
- CLI：stdin → stdout
"""

import subprocess
import sys
import unittest
from pathlib import Path

LIB = Path(__file__).resolve().parents[1] / "lib"
sys.path.insert(0, str(LIB))

SCRIPT = LIB / "sanitize_acceptance_logs.py"


class SanitizeAcceptanceLogsTest(unittest.TestCase):
    def setUp(self):
        self.assertTrue(SCRIPT.exists(), "sanitize_acceptance_logs.py does not exist yet")
        import sanitize_acceptance_logs

        self.sanitize = sanitize_acceptance_logs.sanitize_text

    def test_preserves_ordinary_log_lines(self):
        line = "2026-07-17T15:00:00 INFO  c.b.w.agent.GenerationWorker - claimed job 42, status=PENDING\n"
        self.assertEqual(self.sanitize(line), line)

    def test_redacts_jwt(self):
        jwt = "eyJhbGciOiJIUzI1NiJ9.eyJ1c2VyX2lkIjo0Mn0.dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        out = self.sanitize(f"incoming Authorization header value: {jwt}\n")
        self.assertNotIn(jwt, out)
        self.assertIn("[REDACTED_JWT]", out)

    def test_redacts_bearer_token(self):
        out = self.sanitize("Authorization: Bearer abcdef123456.token-value_~\n")
        self.assertNotIn("abcdef123456", out)
        self.assertIn("Bearer [REDACTED]", out)

    def test_redacts_secret_key_values(self):
        cases = [
            ("MYSQL_PASSWORD=sup3r-secret", "MYSQL_PASSWORD"),
            ('"access_token": "tok-abc-123"', "access_token"),
            ("refresh_token: tok-xyz-789", "refresh_token"),
            ("secret = hunter2", "secret"),
            ('"OPENAI_API_KEY":"sk-live-abc"', "OPENAI_API_KEY"),
        ]
        for raw, key in cases:
            with self.subTest(raw=raw):
                out = self.sanitize(raw + "\n")
                self.assertNotIn(raw.split("=", 1)[-1].split(":", 1)[-1].strip(' "\n'), out)
                self.assertIn(key, out, "key name must stay for diagnosability")
                self.assertIn("[REDACTED]", out)

    def test_multiline_mixed_content(self):
        body = (
            "INFO connected to mysql:3306\n"
            "DEBUG Authorization: Bearer secret-bearer-token\n"
            "INFO job 7 finished, asset stored\n"
        )
        out = self.sanitize(body)
        self.assertIn("INFO connected to mysql:3306", out)
        self.assertIn("INFO job 7 finished, asset stored", out)
        self.assertNotIn("secret-bearer-token", out)

    def test_strips_stack_frames_but_keeps_headline(self):
        body = (
            "bw-acc-agent  | 2026-07-17 ERROR c.b.w.agent.SomeService - job failed\n"
            "bw-acc-agent  | java.lang.IllegalStateException: boom\n"
            "bw-acc-agent  | \tat com.blue.whale.agent.SomeService.fail(SomeService.java:42)\n"
            "bw-acc-agent  | \tat org.springframework.Base(Base.java:1)\n"
            "bw-acc-agent  | \t... 8 common frames omitted\n"
            "bw-acc-agent  | Caused by: java.lang.IllegalArgumentException: bad input\n"
            "bw-acc-agent  | \tat com.blue.whale.agent.Other.other(Other.java:7)\n"
            "bw-acc-agent  | INFO recovered\n"
        )
        out = self.sanitize(body)
        self.assertIn("job failed", out)
        self.assertIn("IllegalStateException: boom", out)
        self.assertIn("IllegalArgumentException: bad input", out)
        self.assertIn("INFO recovered", out)
        self.assertNotIn("SomeService.java:42", out)
        self.assertNotIn("Base.java:1", out)
        self.assertNotIn("common frames omitted", out)
        self.assertNotIn("Other.java:7", out)

    def test_cli_stdin_to_stdout(self):
        payload = "token=abc123\nplain line\n"
        result = subprocess.run(
            [sys.executable, str(SCRIPT)],
            input=payload,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("abc123", result.stdout)
        self.assertIn("plain line", result.stdout)


if __name__ == "__main__":
    unittest.main()
