#!/usr/bin/env bash
# validate-json.sh — the JSON gate: runs `jq .` over every plugin.json/hooks.json
# under packages/*/.claude-plugin/ and packages/*/hooks/, plus the root
# .claude-plugin/marketplace.json. Exits non-zero if any file is malformed.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
rc=0

while IFS= read -r f; do
  jq -e . "$f" >/dev/null 2>&1 || { echo "INVALID JSON: $f"; rc=1; }
done < <(find "$ROOT/.claude-plugin" "$ROOT/packages" -type f -name '*.json' \
  \( -path '*/.claude-plugin/*' -o -path '*/hooks/*' \) 2>/dev/null | sort)

exit $rc
