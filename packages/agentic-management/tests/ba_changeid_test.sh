#!/usr/bin/env bash
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/../../../tests/lib/assert.sh"
. "$DIR/../lib/ba-changeid.sh"
assert_eq "add-user-login" "$(ba_changeid 'Add User Login')" "kebab-cases a title"
assert_eq "add-user-login" "$(ba_changeid '  Add   User: Login!  ')" "collapses punctuation/space, trims"
assert_eq "$(ba_changeid 'Export CSV')" "$(ba_changeid 'Export CSV')" "idempotent for same input"
assert_eq "billing-webhooks" "$(ba_changeid 'Billing / Webhooks')" "slash becomes single dash"
assert_summary
