#!/usr/bin/env bash
# Thin operator entry for the PM loop. Dry-run by default so a mis-run spends nothing.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${PM_DRY_RUN:=1}"; export PM_DRY_RUN
if [ "$PM_DRY_RUN" = "1" ]; then
  echo "pm-run: starting in DRY-RUN mode (set PM_DRY_RUN=0 to launch engineers)."
fi
"$HERE/pm-runner.sh" "$@"
rc=$?
if [ "$rc" -eq 0 ] && [ "$PM_DRY_RUN" = "1" ]; then
  echo "pm-run: next steps — review selection above, then re-run with PM_DRY_RUN=0."
fi
exit "$rc"
