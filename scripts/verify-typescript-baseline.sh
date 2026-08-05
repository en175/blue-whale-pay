#!/usr/bin/env bash

set -euo pipefail

[ "$(node --version)" = "v24.18.0" ] || { echo "Node.js 24.18.0 is required" >&2; exit 1; }
[ "$(pnpm --version)" = "11.17.0" ] || { echo "pnpm 11.17.0 is required" >&2; exit 1; }

pnpm typecheck
pnpm build:node
pnpm test
pnpm --filter blue_whale build
pnpm test:acceptance
