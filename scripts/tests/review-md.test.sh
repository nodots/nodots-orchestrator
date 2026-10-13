#!/usr/bin/env bash
# Fixture test for REVIEW.md: the three passes, the finding format, the nit cap,
# the never-blocks statement, the manual run procedure, and no workflow or secret.
set -uo pipefail
cd "$(dirname "$0")"
. ../../plugins/fleet/tests/lib.sh

ROOT="$(cd ../.. && pwd -P)"
F="$ROOT/REVIEW.md"
assert_file "$F" "REVIEW.md exists at the repo root"
[ -f "$F" ] || finish
DOC=$(cat "$F")

assert_contains "$DOC" "Bugs and logic errors" "pass 1: bugs and logic errors"
assert_contains "$DOC" "Security" "pass 2: security"
assert_contains "$DOC" "Compliance" "pass 3: compliance with the package issue and worker contract"
assert_contains "$DOC" "worker contract" "pass 3 names the worker contract"
assert_contains "$DOC" "names its pass" "each finding names its pass"
assert_contains "$DOC" "Important" "defines Important"
assert_contains "$DOC" "nit" "defines nits"
assert_contains "$DOC" "at most 5 nits" "nit cap of 5"
assert_contains "$DOC" "count" "remaining nits summarized as a count"
assert_contains "$DOC" "Excluded paths" "excluded paths section"
assert_contains "$DOC" "never approve or block" "findings never approve or block alone"
assert_contains "$DOC" "How to run a review" "run section"
assert_contains "$DOC" "gh pr diff" "run section names gh pr diff"
assert_contains "$DOC" "gh pr view" "run section names gh pr view"
assert_contains "$DOC" "[bugs]" "tag format: bugs"
assert_contains "$DOC" "[security]" "tag format: security"
assert_contains "$DOC" "[compliance]" "tag format: compliance"

assert_empty "$(ls "$ROOT"/.github/workflows/review*.yml 2>/dev/null)" "no review workflow file"
assert_empty "$(grep -E -- 'sk-ant-|ANTHROPIC_API_KEY *[:=] *[^ $]|ghp_[A-Za-z0-9]{20}' "$F")" "no credential value in REVIEW.md"

finish
