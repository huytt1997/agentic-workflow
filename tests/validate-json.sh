#!/usr/bin/env bash
# validate-json.sh — the JSON gate: runs `jq .` over every hooks.json under
# packages/*/hooks/. The marketplace.json/plugin.json manifests were removed when
# the Claude-plugin install mechanism was retired (see .agentic/plans/01-retire-plugin.md);
# hooks.json is retained as install data (see 00-overview.md D-B).
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
rc=0

while IFS= read -r f; do
  jq -e . "$f" >/dev/null 2>&1 || { echo "INVALID JSON: $f"; rc=1; }
done < <(find "$ROOT/packages" -type f -name '*.json' -path '*/hooks/*' 2>/dev/null | sort)

exit $rc
