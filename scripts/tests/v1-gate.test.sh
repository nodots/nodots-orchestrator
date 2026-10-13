#!/usr/bin/env bash
# V1 gate: the stamp check and the approval setting behave as specified.
#
# Stamp: a READY PR is judged by scripts/check-stamp.js. The head shas come from
# a real temporary git repo, so "a later push" is a real second commit: the
# stamp names the first commit, the PR head is the second.
# Approval: the same PR with no approval, judged by approvalGate with
# approvalEnforcement off and then on (each mechanism).
set -uo pipefail
cd "$(dirname "$0")"
. ../../plugins/fleet/tests/lib.sh

ROOT="$(cd ../.. && pwd -P)"
CHECK="$ROOT/scripts/check-stamp.js"
CONFIG="$ROOT/plugins/fleet/src/config.js"
WORKFLOW="$ROOT/.github/workflows/stamp-check.yml"
assert_file "$CHECK" "scripts/check-stamp.js exists"
assert_file "$CONFIG" "plugins/fleet/src/config.js exists"
assert_file "$WORKFLOW" "the stamp-check workflow exists"
assert_contains "$(cat "$WORKFLOW")" "node scripts/check-stamp.js" "the workflow runs scripts/check-stamp.js"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# --- stamp ---------------------------------------------------------------------

REPO="$TMP/repo"
mkdir -p "$REPO"
(
  cd "$REPO" || exit 1
  git init -q -b work .
  git config user.email t@example.com
  git config user.name t
  git config commit.gpgsign false
  printf 'one\n' > f.txt
  git add f.txt
  git commit -q -m first
)
FIRST=$(git -C "$REPO" rev-parse HEAD)
(
  cd "$REPO" || exit 1
  printf 'two\n' > f.txt
  git commit -q -am "later push"
)
HEAD_SHA=$(git -C "$REPO" rev-parse HEAD)
assert_ne "$FIRST" "$HEAD_SHA" "the later push moved the head sha"

TITLE="[READY]: V1 gate fixture"

# run_pr <comments-json-array> — check a READY PR whose head is HEAD_SHA.
run_pr() {
  node -e 'process.stdout.write(JSON.stringify({title: process.argv[1], headSha: process.argv[2], comments: JSON.parse(process.argv[3])}))' \
    "$TITLE" "$HEAD_SHA" "$1" > "$TMP/pr.json"
  OUT=$(node "$CHECK" "$TMP/pr.json" 2>&1); RC=$?
}

run_pr '[]'
assert_ne "0" "$RC" "no stamp: flagged"
assert_contains "$OUT" "$HEAD_SHA" "no stamp: the failure names the head sha"

run_pr "[\"VERIFIED: bash scripts/test.sh @ $FIRST\\n\\nALL PASS\"]"
assert_ne "0" "$RC" "stale stamp after a later push: flagged"
assert_contains "$OUT" "$HEAD_SHA" "stale stamp: the failure names the head sha"

run_pr "[\"VERIFIED: bash scripts/test.sh @ $FIRST\",\"VERIFIED: bash scripts/test.sh @ $HEAD_SHA\\n\\nALL PASS\"]"
assert_eq "0" "$RC" "current stamp: passes"
assert_contains "$OUT" "VERIFIED bash scripts/test.sh @ $HEAD_SHA" "current stamp: the pass names the stamp"

# --- approval ------------------------------------------------------------------

mkdir -p "$TMP/plugins/agentic-work-packages/.claude-plugin"
printf '{"name":"x"}' > "$TMP/plugins/agentic-work-packages/.claude-plugin/plugin.json"
BASE="{repo:'acme/host',epic:1,targets:[{repo:'api',localPath:'./api'}],workers:{a:{mode:'local'}},pluginRoot:'$TMP/plugins/agentic-work-packages'}"
PR="{number:34,approvals:[]}"

# gate <extra-config> — print approvalGate(...).blocked for the no-approval PR.
gate() { node -e "const c=require('$CONFIG'); const v=c.validate({...$BASE$1},'$TMP'); console.log(c.approvalGate(v,$PR).blocked)"; }

assert_eq "false" "$(gate '')" "approval off (default): a PR with no approval is not blocked"
assert_eq "false" "$(gate ",approvalEnforcement:'off'")" "approval off (explicit): a PR with no approval is not blocked"
for m in branch-protection ruleset; do
  assert_eq "true" "$(gate ",approvalEnforcement:'$m'")" "approval on ($m): the same PR is blocked"
done

finish
