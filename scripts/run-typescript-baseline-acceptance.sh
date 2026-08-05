#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE_FILE="$ROOT/deploy/typescript-baseline/docker-compose.acceptance.yml"
PROJECT="${BW_TS_COMPOSE_PROJECT:-bw-ts-baseline-acceptance}"
NEW_API_BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/bw-new-api-acceptance.XXXXXX")"
NEW_API_SOURCE_DIR="$NEW_API_BUILD_DIR/source"
export BW_NEW_API_BINARY="$NEW_API_BUILD_DIR/new-api"

dc() {
  docker compose -p "$PROJECT" -f "$COMPOSE_FILE" "$@"
}

# Invoked indirectly by the EXIT trap.
# shellcheck disable=SC2329
cleanup() {
  dc down -v --remove-orphans >/dev/null 2>&1 || true
  rm -rf "$NEW_API_BUILD_DIR"
}
trap cleanup EXIT

GIT_COMMIT="$(git -C "$ROOT" rev-parse --short HEAD)"
BUILD_TIME="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
export GIT_COMMIT BUILD_TIME
export BW_TS_COMPOSE_FILE="$COMPOSE_FILE"
export BW_TS_COMPOSE_PROJECT="$PROJECT"

mkdir -p \
  "$NEW_API_SOURCE_DIR/web/default/dist" \
  "$NEW_API_SOURCE_DIR/web/classic/dist"
git -C "$ROOT" archive HEAD:blue_whale_api | tar -x -C "$NEW_API_SOURCE_DIR"
printf '%s\n' '<!doctype html><title>acceptance</title>' \
  >"$NEW_API_SOURCE_DIR/web/default/dist/index.html"
printf '%s\n' '<!doctype html><title>acceptance</title>' \
  >"$NEW_API_SOURCE_DIR/web/classic/dist/index.html"
(
  cd "$NEW_API_SOURCE_DIR"
  docker_arch="$(docker info --format '{{.Architecture}}')"
  case "$docker_arch" in
    amd64|x86_64) new_api_goarch=amd64 ;;
    arm64|aarch64) new_api_goarch=arm64 ;;
    *)
      echo "unsupported Docker architecture: $docker_arch" >&2
      exit 1
      ;;
  esac
  CGO_ENABLED=0 GOOS=linux GOARCH="$new_api_goarch" \
    go build -trimpath -ldflags="-s -w" -o "$BW_NEW_API_BINARY" .
)

"$ROOT/scripts/init-typescript-baseline-db.sh"
if [ "${BW_TS_SKIP_IMAGE_BUILD:-false}" = "true" ]; then
  dc up -d new-api provider-stub agent-worker generation-worker web
else
  dc up -d --build new-api provider-stub agent-worker generation-worker web
fi

setup_response="$(
  dc exec -T new-api wget -qO- \
    --header='Content-Type: application/json' \
    --post-data='{"username":"acceptroot","password":"AcceptanceRoot-Only!","confirmPassword":"AcceptanceRoot-Only!","DemoSiteEnabled":false}' \
    http://127.0.0.1:3000/api/setup
)"
if ! printf '%s' "$setup_response" | grep -q '"success":true'; then
  echo "new-api acceptance setup failed" >&2
  exit 1
fi

dc exec -T mysql mysql -uroot -pblue_whale new_api <<'SQL'
INSERT INTO channels (
  id, type, `key`, status, name, weight, created_time, base_url, models,
  `group`, priority, auto_ban, settings
) VALUES
  (
    9001, 1, 'sk-acceptance-upstream', 1, 'acceptance-image', 100,
    UNIX_TIMESTAMP(), 'http://provider-stub:4329',
    'doubao-seedream-4-0-250828', 'default', 100, 0,
    '{"disable_task_polling_sleep":true}'
  ),
  (
    9002, 59, 'sk-acceptance-upstream', 1, 'acceptance-video', 100,
    UNIX_TIMESTAMP(), 'http://provider-stub:4329',
    'doubao-seedance-2-0-260128', 'default', 100, 0,
    '{"disable_task_polling_sleep":true}'
  );
INSERT INTO options (`key`, `value`)
VALUES
  (
    'ModelRatio',
    '{"doubao-seedream-4-0-250828":1,"doubao-seedance-2-0-260128":1}'
  ),
  ('QuotaForNewUser', '10000000')
ON DUPLICATE KEY UPDATE `value` = VALUES(`value`);
SQL
dc restart new-api >/dev/null

deadline=$((SECONDS + 180))
while [ "$SECONDS" -lt "$deadline" ]; do
  pending=0
  for service in new-api provider-stub agent-worker generation-worker web; do
    container_id="$(dc ps -q "$service")"
    if [ -z "$container_id" ] || [ "$(docker inspect -f '{{.State.Health.Status}}' "$container_id")" != "healthy" ]; then
      pending=1
    fi
  done
  if [ "$pending" -eq 0 ]; then
    if node --test \
      "$ROOT/tests/typescript-baseline/fullstack.test.mjs" \
      "$ROOT/tests/typescript-baseline/ik50gb-c-smoke.test.mjs"; then
      provider_requests="$(dc exec -T provider-stub wget -qO- http://127.0.0.1:4329/__acceptance/requests)"
      PROVIDER_REQUESTS="$provider_requests" node -e '
        const requests = JSON.parse(process.env.PROVIDER_REQUESTS).requests;
        for (const pathname of [
          "/v1/images/generations",
          "/v1/video/generations",
          "/v1/video/generations/acceptance-video-task",
        ]) {
          if (!requests.some((item) => item.pathname === pathname && item.authorized === true)) {
            console.error(`authorized provider acceptance request missing: ${pathname}`);
            process.exit(1);
          }
        }
      '
      exit 0
    fi
    dc logs --no-color --tail=200 new-api web generation-worker \
      | python3 "$ROOT/scripts/lib/sanitize_acceptance_logs.py" >&2
    exit 1
  fi
  sleep 2
done

dc ps >&2
dc logs --no-color --tail=200 \
  | python3 "$ROOT/scripts/lib/sanitize_acceptance_logs.py" >&2
echo "TypeScript baseline stack did not become ready" >&2
exit 1
