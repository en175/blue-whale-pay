import os
import pathlib
import subprocess
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "run-ik50gb-c-testsite-probe.sh"


class TestProbeTerminalTimeout(unittest.TestCase):
    def test_rejects_non_numeric_terminal_timeout(self):
        env = os.environ.copy()
        for key in ("BW_ALLOW_INSECURE_HTTP", "BW_TEST_REGISTER", "BW_ALLOW_BILLED_MEDIA_PROBE"):
            env.pop(key, None)
        env.update(
            {
                "BW_TEST_BASE_URL": "https://probe.example",
                "BW_TEST_USERNAME": "probe-user",
                "BW_TEST_PASSWORD": "probe-password",
                "BW_PROBE_TERMINAL_TIMEOUT_SECONDS": "soon",
            }
        )
        result = subprocess.run(
            ["bash", str(SCRIPT)],
            cwd=ROOT,
            env=env,
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(result.returncode, 2)
        self.assertIn("BW_PROBE_TERMINAL_TIMEOUT_SECONDS", result.stderr)


class TestIk50gbCTestsiteProbe(unittest.TestCase):
    def test_fails_closed_without_base_url(self):
        env = os.environ.copy()
        env.pop("BW_TEST_BASE_URL", None)
        env["BW_TEST_USERNAME"] = "probe-user"
        env["BW_TEST_PASSWORD"] = "probe-password"
        result = subprocess.run(
            ["bash", str(SCRIPT)],
            cwd=ROOT,
            env=env,
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("BW_TEST_BASE_URL is required", result.stderr)

    def test_rejects_non_https_remote_url_before_network(self):
        env = os.environ.copy()
        env.update(
            {
                "BW_TEST_BASE_URL": "http://example.invalid",
                "BW_TEST_USERNAME": "probe-user",
                "BW_TEST_PASSWORD": "probe-password",
            }
        )
        result = subprocess.run(
            ["bash", str(SCRIPT)],
            cwd=ROOT,
            env=env,
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(result.returncode, 2)
        self.assertIn("must use HTTPS", result.stderr)

    def test_insecure_http_switch_allows_plain_http_remote(self):
        env = os.environ.copy()
        env.update(
            {
                "BW_TEST_BASE_URL": "http://example.invalid",
                "BW_TEST_USERNAME": "probe-user",
                "BW_TEST_PASSWORD": "probe-password",
                "BW_ALLOW_INSECURE_HTTP": "1",
            }
        )
        result = subprocess.run(
            ["bash", str(SCRIPT)],
            cwd=ROOT,
            env=env,
            capture_output=True,
            text=True,
            check=False,
        )
        # URL 闸门放行后会在网络层失败（域名不可解析），但不得是 HTTPS 拒绝。
        self.assertNotEqual(result.returncode, 2)
        self.assertNotIn("must use HTTPS", result.stderr)

    def test_insecure_http_switch_keeps_userinfo_blocked(self):
        env = os.environ.copy()
        env.update(
            {
                "BW_TEST_BASE_URL": "http://user:pass@example.invalid",
                "BW_TEST_USERNAME": "probe-user",
                "BW_TEST_PASSWORD": "probe-password",
                "BW_ALLOW_INSECURE_HTTP": "1",
            }
        )
        result = subprocess.run(
            ["bash", str(SCRIPT)],
            cwd=ROOT,
            env=env,
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(result.returncode, 2)

    def test_rejects_localhost_userinfo_bypass_before_network(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            marker = pathlib.Path(temp_dir) / "curl-was-called"
            curl = pathlib.Path(temp_dir) / "curl"
            curl.write_text(
                f"#!/usr/bin/env bash\n: > {marker!s}\nexit 99\n",
                encoding="utf-8",
            )
            curl.chmod(0o755)
            env = os.environ.copy()
            env.update(
                {
                    "PATH": f"{temp_dir}:{env['PATH']}",
                    "BW_TEST_BASE_URL": "http://localhost:123@evil.example",
                    "BW_TEST_USERNAME": "probe-user",
                    "BW_TEST_PASSWORD": "probe-password",
                }
            )
            result = subprocess.run(
                ["bash", str(SCRIPT)],
                cwd=ROOT,
                env=env,
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(result.returncode, 2)
            self.assertFalse(marker.exists())

    def test_successful_non_billed_probe_reaches_pass(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            curl = pathlib.Path(temp_dir) / "curl"
            curl.write_text(
                """#!/usr/bin/env python3
import json
import pathlib
import sys

args = sys.argv[1:]
output = pathlib.Path(args[args.index("--output") + 1])
url = args[-1]
if url.endswith("/api/auth/login"):
    body = {"data": {"access_token": "sk-test-only"}}
elif url.endswith("/api/me"):
    body = {"data": {"username": "probe-user"}}
elif url.endswith("/api/usage/token"):
    body = {"data": {"quota": 1000}}
elif url.endswith("/api/projects"):
    body = {"data": {"id": 42}}
elif url.endswith("/conversation/messages"):
    body = {"data": {"id": 7}}
else:
    raise SystemExit(98)
output.write_text(json.dumps(body), encoding="utf-8")
sys.stdout.write("200")
""",
                encoding="utf-8",
            )
            curl.chmod(0o755)
            env = os.environ.copy()
            env.update(
                {
                    "PATH": f"{temp_dir}:{env['PATH']}",
                    "BW_TEST_BASE_URL": "http://127.0.0.1:3101",
                    "BW_TEST_USERNAME": "probe-user",
                    "BW_TEST_PASSWORD": "probe-password",
                }
            )
            result = subprocess.run(
                ["bash", str(SCRIPT)],
                cwd=ROOT,
                env=env,
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("MEDIA probe", result.stdout)
            self.assertIn("SKIPPED", result.stdout)
            self.assertIn("IK50GB-C test-site probe", result.stdout)
            self.assertIn("PASS", result.stdout)

    def test_billed_probe_waits_for_both_terminal_jobs_and_reports_quota_delta(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            curl = pathlib.Path(temp_dir) / "curl"
            curl.write_text(
                """#!/usr/bin/env python3
import json
import pathlib
import sys

args = sys.argv[1:]
output = pathlib.Path(args[args.index("--output") + 1])
url = args[-1]
if url.endswith("/api/auth/login"):
    body = {"data": {"access_token": "sk-test-only"}}
elif url.endswith("/api/me"):
    body = {"data": {"username": "probe-user"}}
elif url.endswith("/api/usage/token"):
    body = {"data": {"quota": 900}}
elif url.endswith("/api/projects"):
    body = {"data": {"id": 42}}
elif url.endswith("/conversation/messages"):
    body = {"data": {"id": 7}}
elif url.endswith("/generation-jobs"):
    request_arg = args[args.index("--data-binary") + 1]
    request = json.loads(pathlib.Path(request_arg[1:]).read_text(encoding="utf-8"))
    job_id = 101 if request["type"] == "image" else 102
    body = {"data": {"generation_job_id": job_id}}
elif "/api/jobs?ids=" in url:
    body = {"data": {"records": [
        {"job_id": 101, "status": "succeeded"},
        {"job_id": 102, "status": "succeeded"},
    ]}}
else:
    raise SystemExit(98)
output.write_text(json.dumps(body), encoding="utf-8")
sys.stdout.write("200")
""",
                encoding="utf-8",
            )
            curl.chmod(0o755)
            env = os.environ.copy()
            env.update(
                {
                    "PATH": f"{temp_dir}:{env['PATH']}",
                    "BW_TEST_BASE_URL": "http://127.0.0.1:3101",
                    "BW_TEST_USERNAME": "probe-user",
                    "BW_TEST_PASSWORD": "probe-password",
                    "BW_ALLOW_BILLED_MEDIA_PROBE": "1",
                }
            )
            result = subprocess.run(
                ["bash", str(SCRIPT)],
                cwd=ROOT,
                env=env,
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("MEDIA terminal state", result.stdout)
            self.assertIn("succeeded", result.stdout)
            self.assertIn("MEDIA quota delta", result.stdout)
            self.assertIn("IK50GB-C test-site probe", result.stdout)
            self.assertIn("PASS", result.stdout)

    def test_contract_is_http_only_sanitized_and_billing_gated(self):
        source = SCRIPT.read_text(encoding="utf-8")
        for forbidden in (
            r"(?m)^\s*mysql(?:\s|$)",
            r"(?m)^\s*redis-cli(?:\s|$)",
            r"docker\s+compose\s+down",
            r"(?m)^\s*\S*migrate(?:\s|$)",
            r"(?m)^\s*\S*seed(?:\s|$)",
            r"--request\s+DELETE",
            r"-X\s+DELETE",
        ):
            self.assertNotRegex(source, forbidden)
        self.assertIn('BW_ALLOW_BILLED_MEDIA_PROBE:-0', source)
        self.assertIn('= "1"', source)
        self.assertNotIn("Set-Cookie", source)
        self.assertNotIn("Cookie:", source)
        self.assertNotRegex(source, r"echo .*BW_TEST_PASSWORD")
        self.assertNotRegex(source, r"printf .*BW_TEST_PASSWORD")
        self.assertIn('--header "@$header_file"', source)


if __name__ == "__main__":
    unittest.main()
