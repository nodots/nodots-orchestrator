#!/usr/bin/env bash
# Fixture test for .github/pull_request_template.md: the incident-to-eval checklist
# item, and the [READY]: and VERIFIED: stamp reminders quoted from the worker contract.
# Removing the eval item must fail this test.
set -uo pipefail
cd "$(dirname "$0")"
. ../../plugins/fleet/tests/lib.sh

ROOT="$(cd ../.. && pwd -P)"
F="$ROOT/.github/pull_request_template.md"
assert_file "$F" "pull_request_template.md exists"
[ -f "$F" ] || finish
DOC=$(cat "$F")

assert_contains "$DOC" "- [ ] A fix for a failure found in practice adds an eval case, or states in one line why not." "eval checklist item"
assert_contains "$DOC" 'title starting `[READY]:`' "[READY]: reminder quoted from the worker contract"
assert_contains "$DOC" "VERIFIED: <suite or run id> @ <full head sha>" "VERIFIED stamp reminder quoted from the worker contract"
assert_contains "$DOC" "A push after the stamp voids it" "stamp voiding reminder quoted from the worker contract"

finish
