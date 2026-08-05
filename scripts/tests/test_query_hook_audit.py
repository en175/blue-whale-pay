#!/usr/bin/env python3
"""Black-box tests for the Hook audit query interface."""

from __future__ import annotations

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "query-hook-audit.py"


class QueryHookAuditTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.repo = Path(self.temp.name) / "repo"
        subprocess.run(
            ["git", "init", "--initial-branch=master", str(self.repo)],
            check=True,
            capture_output=True,
            text=True,
        )
        audit_dir = self.repo / ".git" / "hook-audit"
        audit_dir.mkdir()
        records = (
            {
                "timestamp": "2026-07-15T00:00:00+00:00",
                "hook": "block-master-edit.sh",
                "session_id": "session-a",
                "tool_use_id": "tool-a",
                "exit_code": 2,
            },
            {
                "timestamp": "2026-07-15T00:01:00+00:00",
                "hook": "block-master-edit.sh",
                "session_id": "session-b",
                "tool_use_id": "tool-b",
                "exit_code": 0,
            },
        )
        (audit_dir / "block-master-edit.sh.log").write_text(
            "".join(json.dumps(record) + "\n" for record in records),
            encoding="utf-8",
        )

    def tearDown(self) -> None:
        self.temp.cleanup()

    def invoke(self, *args: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [sys.executable, str(SCRIPT), "--project-dir", str(self.repo), *args],
            capture_output=True,
            text=True,
        )

    def test_filters_by_session_and_tool_use_id(self) -> None:
        result = self.invoke("--session-id", "session-b", "--tool-use-id", "tool-b")

        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual("", result.stderr)
        self.assertEqual("tool-b", json.loads(result.stdout)["tool_use_id"])

    def test_missing_tool_use_id_has_explicit_diagnostic(self) -> None:
        result = self.invoke("--tool-use-id", "tool-missing")

        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual("未进入仓库 Hook 执行链\n", result.stdout)
        self.assertEqual("", result.stderr)


if __name__ == "__main__":
    unittest.main()
