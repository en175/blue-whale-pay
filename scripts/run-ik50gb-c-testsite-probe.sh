#!/usr/bin/env bash

set -euo pipefail

: "${BW_TEST_BASE_URL:?BW_TEST_BASE_URL is required}"
: "${BW_TEST_USERNAME:?BW_TEST_USERNAME is required}"
: "${BW_TEST_PASSWORD:?BW_TEST_PASSWORD is required}"

terminal_timeout_seconds="${BW_PROBE_TERMINAL_TIMEOUT_SECONDS:-180}"
case "$terminal_timeout_seconds" in
  ''|*[!0-9]*)
    echo "BW_PROBE_TERMINAL_TIMEOUT_SECONDS must be a positive integer (seconds)" >&2
    exit 2
    ;;
esac

base_url="${BW_TEST_BASE_URL%/}"
if ! node -e '
  let url;
  try {
    url = new URL(process.argv[1]);
  } catch {
    process.exit(1);
  }
  const isLoopback = ["localhost", "127.0.0.1", "[::1]"].includes(url.hostname);
  // BW_ALLOW_INSECURE_HTTP=1：用户知情豁免——测试站无 TLS 时允许明文 HTTP（userinfo 仍拒绝）。
  const insecureAllowed =
    url.protocol === "http:" &&
    process.env.BW_ALLOW_INSECURE_HTTP === "1";
  const allowed =
    url.username === "" &&
    url.password === "" &&
    (url.protocol === "https:" || (url.protocol === "http:" && isLoopback) || insecureAllowed);
  process.exit(allowed ? 0 : 1);
' "$base_url"; then
  echo "BW_TEST_BASE_URL must use HTTPS unless the host is localhost (set BW_ALLOW_INSECURE_HTTP=1 to knowingly waive TLS), and must not contain userinfo" >&2
  exit 2
fi

probe_tmp="$(mktemp -d "${TMPDIR:-/tmp}/bw-ik50gb-c-probe.XXXXXX")"
chmod 700 "$probe_tmp"
cleanup() {
  rm -rf "$probe_tmp"
}
trap cleanup EXIT

response_file="$probe_tmp/response.json"
request_file="$probe_tmp/request.json"
auth_header_file="$probe_tmp/auth-header"
: >"$response_file"
: >"$request_file"
: >"$auth_header_file"
chmod 600 "$response_file" "$request_file" "$auth_header_file"

json_request() {
  local method="$1"
  local endpoint="$2"
  local body_file="${3:-}"
  local header_file="${4:-}"
  local -a args=(
    --silent
    --show-error
    --output "$response_file"
    --write-out "%{http_code}"
    --request "$method"
    --header "Content-Type: application/json"
  )
  if [ -n "$body_file" ]; then
    args+=(--data-binary "@$body_file")
  fi
  if [ -n "$header_file" ]; then
    args+=(--header "@$header_file")
  fi
  curl "${args[@]}" "$base_url$endpoint"
}

write_credentials() {
  node -e '
    const fs = require("node:fs");
    fs.writeFileSync(process.argv[1], JSON.stringify({
      username: process.env.BW_TEST_USERNAME,
      password: process.env.BW_TEST_PASSWORD,
    }));
  ' "$request_file"
}

report() {
  printf '%-48s %s\n' "$1" "$2"
}

read_quota() {
  node -e '
    const fs = require("node:fs");
    const body = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    const quota = body?.data?.quota;
    if (typeof quota !== "number" || !Number.isFinite(quota)) process.exit(1);
    process.stdout.write(String(quota));
  ' "$response_file"
}

write_credentials
if [ "${BW_TEST_REGISTER:-0}" = "1" ]; then
  code="$(json_request POST /api/auth/register "$request_file")"
  report "POST /api/auth/register" "$code"
  [ "$code" = "200" ] || exit 1
fi

code="$(json_request POST /api/auth/login "$request_file")"
report "POST /api/auth/login" "$code"
[ "$code" = "200" ] || exit 1

token="$(
  node -e '
    const fs = require("node:fs");
    const body = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    const token = body?.data?.access_token;
    if (typeof token !== "string" || !token.startsWith("sk-")) process.exit(1);
    process.stdout.write(token);
  ' "$response_file"
)"
printf 'Authorization: Bearer %s\n' "$token" >"$auth_header_file"
unset token

for endpoint in /api/me; do
  code="$(json_request GET "$endpoint" "" "$auth_header_file")"
  report "GET $endpoint" "$code"
  [ "$code" = "200" ] || exit 1
done
code="$(json_request GET /api/usage/token "" "$auth_header_file")"
report "GET /api/usage/token (before)" "$code"
[ "$code" = "200" ] || exit 1
quota_before="$(read_quota)"

probe_suffix="$(date -u +%Y%m%dT%H%M%SZ)-$$"
node -e '
  const fs = require("node:fs");
  fs.writeFileSync(process.argv[1], JSON.stringify({
    name: `IK50GB-C probe ${process.argv[2]}`,
  }));
' "$request_file" "$probe_suffix"
code="$(json_request POST /api/projects "$request_file" "$auth_header_file")"
report "POST /api/projects" "$code"
[ "$code" = "200" ] || exit 1
project_id="$(
  node -e '
    const fs = require("node:fs");
    const body = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    const id = body?.data?.id;
    if (id === undefined || id === null) process.exit(1);
    process.stdout.write(String(id));
  ' "$response_file"
)"

node -e '
  const fs = require("node:fs");
  fs.writeFileSync(process.argv[1], JSON.stringify({
    client_message_id: `probe-${process.argv[2]}`,
    content: "IK50GB-C HTTP-only probe",
  }));
' "$request_file" "$probe_suffix"
code="$(json_request POST "/api/projects/$project_id/conversation/messages" "$request_file" "$auth_header_file")"
report "POST /api/projects/:id/conversation/messages" "$code"
case "$code" in 200|201|202) ;; *) exit 1 ;; esac

if [ "${BW_ALLOW_BILLED_MEDIA_PROBE:-0}" = "1" ]; then
  job_ids=()
  for media_type in image video; do
    node -e '
      const fs = require("node:fs");
      const type = process.argv[2];
      const parameters = type === "image"
        ? {
            prompt: "IK50GB-C probe blue whale",
            model_id: "doubao-seedream-4-0-250828",
            aspect_ratio: "1:1",
            size: "1K",
          }
        : {
            prompt: "IK50GB-C probe blue whale",
            model_id: "doubao-seedance-2-0-260128",
            aspect_ratio: "16:9",
            resolution: "720p",
            duration: 5,
          };
      fs.writeFileSync(process.argv[1], JSON.stringify({
        type,
        input_asset_ids: [],
        expected_output_count: 1,
        parameters,
      }));
    ' "$request_file" "$media_type"
    code="$(json_request POST "/api/projects/$project_id/generation-jobs" "$request_file" "$auth_header_file")"
    report "POST /api/projects/:id/generation-jobs ($media_type)" "$code"
    [ "$code" = "200" ] || exit 1
    job_id="$(
      node -e '
        const fs = require("node:fs");
        const body = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
        const id = body?.data?.generation_job_id;
        if (id === undefined || id === null || !/^[1-9][0-9]*$/.test(String(id))) {
          process.exit(1);
        }
        process.stdout.write(String(id));
      ' "$response_file"
    )"
    job_ids+=("$job_id")
  done

  job_ids_csv="$(IFS=,; printf '%s' "${job_ids[*]}")"
  terminal_deadline=$((SECONDS + terminal_timeout_seconds))
  while :; do
    code="$(json_request GET "/api/jobs?ids=$job_ids_csv" "" "$auth_header_file")"
    report "GET /api/jobs?ids=... (terminal poll)" "$code"
    [ "$code" = "200" ] || exit 1
    job_state="$(
      node -e '
        const fs = require("node:fs");
        const expected = new Set(process.argv[2].split(","));
        const body = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
        const jobs = body?.data?.records;
        if (!Array.isArray(jobs)) process.exit(1);
        const selected = jobs.filter((job) =>
          expected.has(String(job?.job_id)),
        );
        if (selected.length !== expected.size) {
          process.stdout.write("pending");
        } else if (selected.some((job) => job?.status === "failed")) {
          process.stdout.write("failed");
        } else if (selected.every((job) => job?.status === "succeeded")) {
          process.stdout.write("succeeded");
        } else {
          process.stdout.write("pending");
        }
      ' "$response_file" "$job_ids_csv"
    )"
    case "$job_state" in
      succeeded) break ;;
      failed)
        report "MEDIA terminal state" "FAILED"
        exit 1
        ;;
      pending)
        if (( SECONDS >= terminal_deadline )); then
          report "MEDIA terminal state" "TIMEOUT"
          exit 1
        fi
        sleep 3
        ;;
      *) exit 1 ;;
    esac
  done
  report "MEDIA terminal state" "succeeded"

  code="$(json_request GET /api/usage/token "" "$auth_header_file")"
  report "GET /api/usage/token (after)" "$code"
  [ "$code" = "200" ] || exit 1
  quota_after="$(read_quota)"
  quota_delta="$(
    node -e '
      const before = Number(process.argv[1]);
      const after = Number(process.argv[2]);
      if (!Number.isFinite(before) || !Number.isFinite(after) || after > before) {
        process.exit(1);
      }
      process.stdout.write(String(before - after));
    ' "$quota_before" "$quota_after"
  )"
  report "MEDIA quota delta" "$quota_delta"
else
  report "MEDIA probe" "SKIPPED (set BW_ALLOW_BILLED_MEDIA_PROBE=1 after authorization)"
fi

report "IK50GB-C test-site probe" "PASS"
