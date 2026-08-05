#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE_FILE="$ROOT/deploy/typescript-baseline/docker-compose.acceptance.yml"
PROJECT="${BW_TS_COMPOSE_PROJECT:-bw-ts-baseline-db}"

dc() {
  docker compose -p "$PROJECT" -f "$COMPOSE_FILE" "$@"
}

command -v docker >/dev/null 2>&1 || { echo "docker command not found" >&2; exit 1; }
docker info >/dev/null 2>&1 || { echo "Docker daemon is not running" >&2; exit 1; }

dc down -v --remove-orphans >/dev/null 2>&1 || true
dc up -d mysql

deadline=$((SECONDS + 120))
while [ "$SECONDS" -lt "$deadline" ]; do
  container_id="$(dc ps -a -q mysql)"
  if [ -n "$container_id" ] && [ "$(docker inspect -f '{{.State.Status}}' "$container_id")" = "exited" ]; then
    break
  fi
  if [ -n "$container_id" ] && [ "$(docker inspect -f '{{.State.Health.Status}}' "$container_id")" = "healthy" ]; then
    break
  fi
  sleep 2
done

container_id="$(dc ps -a -q mysql)"
if [ -z "$container_id" ] || [ "$(docker inspect -f '{{.State.Health.Status}}' "$container_id")" != "healthy" ]; then
  dc logs mysql >&2
  echo "fresh MySQL did not become healthy" >&2
  exit 1
fi

seed_counts="$(dc exec -T mysql mysql -uroot -pblue_whale -N -B blue_whale -e \
  "SELECT CONCAT((SELECT COUNT(*) FROM generation_model_capability WHERE enabled = 1), ':', (SELECT COUNT(*) FROM conversations), ':', (SELECT COUNT(*) FROM project_events))")"
if [ "$seed_counts" != "2:0:0" ]; then
  echo "unexpected baseline seed counts: $seed_counts" >&2
  exit 1
fi

echo "fresh MySQL baseline ready ($PROJECT)"
