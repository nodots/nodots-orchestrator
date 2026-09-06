#!/usr/bin/env bash
# Fixture test for sync-cells.sh (N-3), and for the VERIFIED stamp parser the
# evidence rule depends on (N-2).
#
# Every precedence rule gets a row, and the stale-sha row is the one that
# matters: a stamp naming a sha the PR has since moved past is evidence about a
# tree nobody is reviewing, and must not promote the package to awaiting-review.
set -uo pipefail
cd "$(dirname "$0")"
. ./lib.sh

SCRIPT="$(cd ../scripts && pwd -P)/sync-cells.sh"
assert_file "$SCRIPT" "sync-cells.sh exists"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

SHA_HEAD=1111111111111111111111111111111111111111
SHA_OLD=2222222222222222222222222222222222222222

cat > "$TMP/state.json" <<JSON
{
  "repo": "example/host",
  "target": "example/code",
  "issues": [
    {
      "number": 101, "title": "M0.1 frozen protocol", "label": "cell:awaiting-review",
      "branch": "feat/m0-1", "branchExists": true, "blockerOnBranch": false,
      "pr": { "number": 201, "state": "MERGED", "headSha": "$SHA_HEAD", "comments": [] }
    },
    {
      "number": 102, "title": "M1.1 session store", "label": "cell:active",
      "branch": "feat/m1-1", "branchExists": true, "blockerOnBranch": false,
      "pr": { "number": 202, "state": "OPEN", "headSha": "$SHA_HEAD",
              "comments": ["looks good", "VERIFIED: unit+e2e @ $SHA_HEAD\n\nnpm test\n40 passed, 0 skipped"] }
    },
    {
      "number": 103, "title": "M1.2 relay", "label": "cell:active",
      "branch": "feat/m1-2", "branchExists": true, "blockerOnBranch": false,
      "pr": { "number": 203, "state": "OPEN", "headSha": "$SHA_HEAD",
              "comments": ["VERIFIED: unit @ $SHA_OLD\n\nnpm test\n40 passed"] }
    },
    {
      "number": 104, "title": "M1.3 validation", "label": "cell:active",
      "branch": "feat/m1-3", "branchExists": true, "blockerOnBranch": true,
      "pr": null
    },
    {
      "number": 105, "title": "M1.4 clock", "label": "cell:queued",
      "branch": "feat/m1-4", "branchExists": true, "blockerOnBranch": false,
      "pr": null
    },
    {
      "number": 106, "title": "M2.1 lobby", "label": "cell:queued",
      "branch": null, "branchExists": false, "blockerOnBranch": false,
      "pr": null
    },
    {
      "number": 107, "title": "M2.2 sync", "label": "cell:blocked",
      "branch": "feat/m2-2", "branchExists": true, "blockerOnBranch": true,
      "pr": { "number": 207, "state": "OPEN", "headSha": "$SHA_HEAD", "comments": [] }
    },
    {
      "number": 108, "title": "M2.3 stale-close", "label": "cell:active",
      "branch": "feat/m2-3", "branchExists": true, "blockerOnBranch": false,
      "pr": { "number": 208, "state": "CLOSED", "headSha": "$SHA_HEAD", "comments": [] }
    }
  ]
}
JSON

OUT=$(bash "$SCRIPT" --state "$TMP/state.json" 2>"$TMP/err")
EXIT=$?
assert_eq 0 "$EXIT" "a dry run over a fixture exits 0"
assert_empty "$(cat "$TMP/err")" "a dry run over a fixture writes nothing to stderr"

row() { printf '%s' "$OUT" | grep -E "^#$1 " || true; }

assert_contains "$(row 101)" "cell:merged"          "merged PR wins over every other rule"
assert_contains "$(row 102)" "cell:awaiting-review" "open PR with a current stamp is awaiting review"
assert_contains "$(row 102)" "unit+e2e"             "the derivation names the suite from the stamp"
assert_contains "$(row 103)" "unchanged"            "a stamp naming a superseded sha does not promote"
assert_not_contains "$(row 103)" "awaiting-review"  "a stale stamp is not evidence for this head"
assert_contains "$(row 104)" "cell:blocked"         "BLOCKER.md on the branch blocks"
assert_contains "$(row 105)" "cell:active"          "a branch with no PR is active"
assert_contains "$(row 106)" "unchanged"            "no branch and no PR leaves the label alone"
assert_contains "$(row 107)" "cell:blocked"         "an open PR without a stamp yields to a blocker"
assert_contains "$(row 108)" "cell:active"          "a closed, unmerged PR falls through to the branch rule"

assert_contains "$OUT" "Dry run" "the default run says it wrote nothing"
assert_not_contains "$OUT" "label(s) written" "the default run does not claim a write"

# The stale-sha row is N-2's acceptance: state it once more, on its own.
stale=$(row 103)
assert_contains "$stale" "cell:active" "the stale-stamp package keeps the label it had"

# --apply without --repo must refuse rather than half-run.
OUT2=$(bash "$SCRIPT" --state "$TMP/state.json" --apply 2>&1)
assert_contains "$OUT2" "--apply needs --repo" "--apply over a bare fixture refuses"

# An unreadable state file fails loudly rather than reporting an empty plan.
OUT3=$(bash "$SCRIPT" --state "$TMP/nope.json" 2>&1); EXIT3=$?
assert_ne 0 "$EXIT3" "a missing state file is an error"
assert_contains "$OUT3" "no such state file" "the missing state file is named"

# Neither --state nor --repo is a usage error, not a silent no-op.
OUT4=$(bash "$SCRIPT" 2>&1); EXIT4=$?
assert_ne 0 "$EXIT4" "no arguments is an error"
assert_contains "$OUT4" "required" "the usage error says what is required"

finish
