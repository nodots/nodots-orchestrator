#!/usr/bin/env bash
# Fixture test for scripts/check-stamp.js: a READY PR needs a VERIFIED stamp
# whose sha equals the PR head sha. Also checks the stamp pattern has one definition.
set -uo pipefail
cd "$(dirname "$0")"
. ../../plugins/fleet/tests/lib.sh

CHECK="$(cd .. && pwd -P)/check-stamp.js"
ROOT="$(cd ../.. && pwd -P)"
assert_file "$CHECK" "scripts/check-stamp.js exists"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

HEAD_SHA=1111111111111111111111111111111111111111
OLD_SHA=2222222222222222222222222222222222222222

# run_pr <title> <comments-json-array> — run the check on a PR whose head is HEAD_SHA.
run_pr() {
  node -e 'process.stdout.write(JSON.stringify({title: process.argv[1], headSha: process.argv[2], comments: JSON.parse(process.argv[3])}))' \
    "$1" "$HEAD_SHA" "$2" > "$TMP/pr.json"
  OUT=$(node "$CHECK" "$TMP/pr.json" 2>&1); RC=$?
}

run_pr "[READY]: G1.2 stamp check" '[]'
assert_ne "0" "$RC" "READY PR with no comments fails"
assert_contains "$OUT" "VERIFIED" "the failure names the missing stamp"

run_pr "[READY]: G1.2 stamp check" '["looks good","not a stamp"]'
assert_ne "0" "$RC" "READY PR with only unrelated comments fails"

run_pr "[READY]: G1.2 stamp check" "[\"VERIFIED: unit @ $OLD_SHA\\n\\nnpm test\"]"
assert_ne "0" "$RC" "READY PR whose stamp names an older sha fails"
assert_contains "$OUT" "$HEAD_SHA" "the failure names the head sha"

run_pr "[READY]: G1.2 stamp check" "[\"VERIFIED: unit @ $OLD_SHA\",\"VERIFIED: unit+e2e @ $HEAD_SHA\\n\\nnpm test\"]"
assert_eq "0" "$RC" "READY PR with a stamp on the head sha passes"

run_pr "[READY]: G1.2 stamp check" "[\"VERIFIED: unit @ $HEAD_SHA\",\"VERIFIED: unit @ $OLD_SHA\"]"
assert_eq "0" "$RC" "a current stamp passes even when an older stamp follows it"

run_pr "G1.2 stamp check" '[]'
assert_eq "0" "$RC" "a PR whose title lacks [READY]: is ignored"

run_pr "WIP [READY]: G1.2" '[]'
assert_eq "0" "$RC" "[READY]: not at the start of the title is ignored"

printf '{"title":"[READY]: x","comments":[]}' > "$TMP/nosha.json"
OUT=$(node "$CHECK" "$TMP/nosha.json" 2>&1); RC=$?
assert_ne "0" "$RC" "a READY PR with no head sha fails rather than passing"

OUT=$(node "$CHECK" "$TMP/missing.json" 2>&1); RC=$?
assert_ne "0" "$RC" "an unreadable input fails"

# --- the review policy, read from the base branch's manifest ---------------
# run_policy <title> <manifest-json-or-null> <comments-json-array> — as run_pr,
# with `manifest` the raw text of .claude/standards.json (null when absent).
run_policy() {
  node -e '
    const [title, sha, manifest, comments] = process.argv.slice(1);
    const m = JSON.parse(manifest);
    process.stdout.write(JSON.stringify({ title, headSha: sha,
      manifest: m === null ? null : (typeof m === "string" ? m : JSON.stringify(m)),
      comments: JSON.parse(comments) }));
  ' "$1" "$HEAD_SHA" "$2" "$3" > "$TMP/pr.json"
  OUT=$(node "$CHECK" "$TMP/pr.json" 2>&1); RC=$?
}

V="VERIFIED: unit @ $HEAD_SHA"
POLICY2='{"version":1,"checks":[],"review":{"passes":2}}'

run_policy "[READY]: R0.3" 'null' "[\"$V\"]"
assert_eq "0" "$RC" "no manifest: a current VERIFIED stamp passes as before"

run_policy "[READY]: R0.3" '{"version":1,"checks":[]}' "[\"$V\"]"
assert_eq "0" "$RC" "a manifest without a review policy: passes as before"

run_policy "[READY]: R0.3" '{"version":1,"checks":[],"review":null}' "[\"$V\"]"
assert_eq "0" "$RC" "review: null is no policy: passes as before"

run_policy "[READY]: R0.3" "$POLICY2" "[\"$V\",\"REVIEWED: alice @ $HEAD_SHA\",\"REVIEWED: bob @ $HEAD_SHA\"]"
assert_eq "0" "$RC" "policy met: two reviewers at the head pass"
assert_contains "$OUT" "REVIEWED alice, bob" "the pass names the reviews counted"

run_policy "[READY]: R0.3" "$POLICY2" "[\"$V\",\"REVIEWED: alice @ $HEAD_SHA\"]"
assert_ne "0" "$RC" "too few passes: one review against passes 2 fails"
assert_contains "$OUT" "alice" "the failure names the review stamps found"
assert_contains "$OUT" "missing 1 review" "the failure names how many are missing"

run_policy "[READY]: R0.3" "$POLICY2" "[\"$V\",\"REVIEWED: alice @ $HEAD_SHA\",\"REVIEWED: alice @ $HEAD_SHA\"]"
assert_ne "0" "$RC" "the same reviewer stamped twice is one review and fails"
assert_contains "$OUT" "missing 1 review" "a repeated reviewer leaves one missing"

run_policy "[READY]: R0.3" "$POLICY2" "[\"$V\",\"REVIEWED: alice @ $HEAD_SHA\",\"REVIEWED: bob @ $OLD_SHA\"]"
assert_ne "0" "$RC" "a review stamp at an old head does not count"
assert_not_contains "$OUT" "bob" "the stale reviewer is not named as found"

run_policy "[READY]: R0.3" "$POLICY2" '[]'
assert_ne "0" "$RC" "no stamps at all fails"
assert_contains "$OUT" "REVIEWED none" "the failure says no review stamps were found"

run_policy "[READY]: R0.3" "$POLICY2" "[\"REVIEWED: alice @ $HEAD_SHA\",\"REVIEWED: bob @ $HEAD_SHA\"]"
assert_ne "0" "$RC" "reviews met do not stand in for a missing VERIFIED stamp"

run_policy "R0.3 draft" "$POLICY2" '[]'
assert_eq "0" "$RC" "a PR not titled [READY]: is not held to the policy"

run_policy "[READY]: R0.3" '"{ not json"' "[\"$V\"]"
assert_ne "0" "$RC" "a manifest that is not JSON fails rather than passing"

run_policy "[READY]: R0.3" '{"review":{"passes":0}}' "[\"$V\"]"
assert_ne "0" "$RC" "an invalid review policy fails rather than passing"
assert_contains "$OUT" "review.passes" "the failure names the policy defect"

# One definition of the stamp pattern in the repo, outside tests.
N=$(cd "$ROOT" && git grep --untracked -n -F 'VERIFIED:\s' -- '*.js' '*.sh' ':!*.test.sh' | wc -l | tr -d ' ')
assert_eq "1" "$N" "exactly one definition of the stamp pattern outside tests"

finish
