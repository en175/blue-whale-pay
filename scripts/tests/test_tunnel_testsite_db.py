import os
import pathlib
import socket
import subprocess
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "tunnel-testsite-db.sh"


def run(args):
    return subprocess.run(
        ["bash", str(SCRIPT), *args],
        cwd=ROOT,
        capture_output=True,
        text=True,
        check=False,
        timeout=15,
    )


class TestTunnelTestsiteDb(unittest.TestCase):
    def test_help_shows_usage(self):
        result = run(["--help"])
        self.assertEqual(result.returncode, 2)
        self.assertIn("--local-port", result.stderr)
        self.assertIn("--timeout", result.stderr)

    def test_rejects_non_numeric_local_port(self):
        result = run(["--local-port", "abc"])
        self.assertEqual(result.returncode, 2)
        self.assertIn("正整数", result.stderr)

    def test_rejects_privileged_local_port(self):
        result = run(["--local-port", "80"])
        self.assertEqual(result.returncode, 2)
        self.assertIn("1024-65535", result.stderr)

    def test_rejects_non_numeric_timeout(self):
        result = run(["--timeout", "soon"])
        self.assertEqual(result.returncode, 2)
        self.assertIn("非负整数", result.stderr)

    def test_fails_closed_when_local_port_is_busy(self):
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as busy:
            busy.bind(("127.0.0.1", 0))
            busy.listen(1)
            port = busy.getsockname()[1]
            result = run(["--local-port", str(port)])
        self.assertEqual(result.returncode, 1)
        self.assertIn("已被占用", result.stderr)


if __name__ == "__main__":
    unittest.main()
