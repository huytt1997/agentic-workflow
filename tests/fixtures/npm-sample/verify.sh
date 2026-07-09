#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
[ -d node_modules ] || npm install --no-audit --no-fund
npm run lint && npm run typecheck && npm test
