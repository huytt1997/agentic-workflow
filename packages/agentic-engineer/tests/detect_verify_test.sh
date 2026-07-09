#!/usr/bin/env bash
# detect_verify_test.sh — proof for the Node-first verify auto-detect script
# (feature `detect-verify`, T-E7).
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"; . "$ROOT/tests/lib/assert.sh"
D="$ROOT/packages/agentic-engineer/lib/detect-verify.sh"

# --- full npm fixture: lint + typecheck + test (component/unit runner) ---
out="$(bash "$D" "$ROOT/tests/fixtures/npm-sample")"
assert_exit 0 "$(jq -e . >/dev/null 2>&1 <<<"$out" && echo 0 || echo 1)" "npm-sample output is valid JSON"
assert_contains "$(jq -r .fast <<<"$out")" "lint" "fast includes lint"
assert_contains "$(jq -r .fast <<<"$out")" "typecheck" "fast includes typecheck"
assert_contains "$(jq -r .component <<<"$out")" "test" "component maps to test script (npm run test)"
assert_contains "$(jq -r .large <<<"$out")" "lint" "large includes lint"
assert_contains "$(jq -r .large <<<"$out")" "typecheck" "large includes typecheck"
assert_contains "$(jq -r .large <<<"$out")" "test" "large includes component/test"
assert_contains "$(jq -r .fast <<<"$out")" " && " "fast joins multiple steps with ' && ' (not space-joined)"
assert_contains "$(jq -r .large <<<"$out")" " && " "large joins multiple steps with ' && ' (not space-joined)"

# --- a full project with lint/typecheck/test:unit/test:integration/test:e2e ---
FULL="$(mktemp -d)"
cat >"$FULL/package.json" <<'EOF'
{
  "scripts": {
    "lint": "eslint .",
    "typecheck": "tsc --noEmit",
    "test:unit": "node --test test/unit",
    "test:integration": "node --test test/integration",
    "test:e2e": "playwright test"
  }
}
EOF
out_full="$(bash "$D" "$FULL")"
assert_contains "$(jq -r .component <<<"$out_full")" "test:unit" "test:unit chosen as component runner"
assert_contains "$(jq -r .large <<<"$out_full")" "test:unit" "large includes test:unit"
assert_contains "$(jq -r .large <<<"$out_full")" "test:integration" "large includes test:integration"
assert_contains "$(jq -r .large <<<"$out_full")" "test:e2e" "large includes test:e2e"
assert_contains "$(jq -r .large <<<"$out_full")" " && " "large (5 steps) joins with ' && ' (not space-joined)"

# --- minimal project: only lint + typecheck, no component/unit runner ---
MIN="$(mktemp -d)"
printf '{"scripts":{"lint":"eslint .","typecheck":"tsc --noEmit"}}' > "$MIN/package.json"
out_min="$(bash "$D" "$MIN")"
assert_eq "null" "$(jq -r .component <<<"$out_min")" "no test script -> component:null"
assert_eq "$(jq -r .fast <<<"$out_min")" "$(jq -r .large <<<"$out_min")" "no component -> FAST falls back, equal to large"
assert_contains "$(jq -r .fast <<<"$out_min")" "lint" "fallback fast still includes lint"
assert_contains "$(jq -r .fast <<<"$out_min")" "typecheck" "fallback fast still includes typecheck"

# --- package manager detection from lockfiles ---
PNPM="$(mktemp -d)"
printf '{"scripts":{"lint":"eslint ."}}' > "$PNPM/package.json"
: > "$PNPM/pnpm-lock.yaml"
out_pnpm="$(bash "$D" "$PNPM")"
assert_contains "$(jq -r .fast <<<"$out_pnpm")" "pnpm" "pnpm lockfile -> pnpm run in fast cmd"

YARN="$(mktemp -d)"
printf '{"scripts":{"lint":"eslint ."}}' > "$YARN/package.json"
: > "$YARN/yarn.lock"
out_yarn="$(bash "$D" "$YARN")"
assert_contains "$(jq -r .fast <<<"$out_yarn")" "yarn" "yarn lockfile -> yarn run in fast cmd"

NPM="$(mktemp -d)"
printf '{"scripts":{"lint":"eslint ."}}' > "$NPM/package.json"
: > "$NPM/package-lock.json"
out_npm="$(bash "$D" "$NPM")"
assert_contains "$(jq -r .fast <<<"$out_npm")" "npm run" "npm lockfile -> npm run in fast cmd"

# --- non-Node dir: no package.json -> graceful nulls ---
NONE="$(mktemp -d)"
out_none="$(bash "$D" "$NONE")"
assert_exit 0 "$(jq -e . >/dev/null 2>&1 <<<"$out_none" && echo 0 || echo 1)" "non-Node dir still emits valid JSON"
assert_eq "null" "$(jq -r .fast <<<"$out_none")" "non-Node dir -> fast:null"
assert_eq "null" "$(jq -r .component <<<"$out_none")" "non-Node dir -> component:null"
assert_eq "null" "$(jq -r .large <<<"$out_none")" "non-Node dir -> large:null"

assert_summary
