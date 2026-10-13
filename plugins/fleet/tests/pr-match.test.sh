#!/usr/bin/env bash
# Fixture test for FX1: a PR belongs to a package only by its head branch, and a
# parked package whose blocker is removed is never unparked when a PR exists.
set -uo pipefail
cd "$(dirname "$0")"
. ./lib.sh

SRC="$(cd .. && pwd -P)/src/reap.js"
STORE="$(cd .. && pwd -P)/src/store.js"
assert_file "$SRC" "reap.js exists"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
TMP=$(cd "$TMP" && pwd -P)
mkdir -p "$TMP/wt"

js() { node -e "const r=require('$SRC'); $1"; }
S="{issue:12,id:'V1',branch:'feat/v1-real',status:'running',attempt:1,tier:'default',worktree:'$TMP/wt'}"

# --- (1) prFor: exact head branch only ---------------------------------------
assert_eq "null" "$(js "console.log(r.prFor($S,[{number:7,title:'V1 throwaway',body:'Closes #12',headRefName:'scratch/other'}]))")" "a PR titled with the package id on a different head branch does not match"
assert_eq "null" "$(js "console.log(r.prFor($S,[{number:8,title:'[READY]: other #12',body:'',headRefName:'scratch/x'}]))")" "an issue reference in the title on a different head branch does not match"
assert_eq "9" "$(js "console.log(r.prFor($S,[{number:7,title:'V1 throwaway',body:'',headRefName:'scratch/other'},{number:9,title:'unrelated',body:'',headRefName:'feat/v1-real'}]).number)")" "the PR whose head branch equals the package branch matches whatever its title says"

# --- reap over a parked session ----------------------------------------------
# run <pulls-js> -> prints status, outcome, request list, reaped list for session 12
run_parked() {
  node - "$SRC" "$TMP" "$1" <<'JS'
const r = require(process.argv[2]); const T = process.argv[3];
const pulls = eval(process.argv[4]);
const state = { sessions: { 12: { issue: 12, id: 'V1', branch: 'feat/v1-real', status: 'parked', outcome: 'parked', attempt: 1, tier: 'default', worktree: T + '/wt', pid: null } } };
const out = r.reap({ sessionTimeoutMinutes: 120, killGraceSeconds: 60 }, state, pulls, Date.now(), () => false);
const s = state.sessions[12];
console.log(s.status, s.outcome, out.requests.map(q => q.next).join(',') || '-', out.reaped.map(x => x.outcome).join(',') || '-');
JS
}

# --- (2) blocker removed, merged PR on the package branch --------------------
assert_eq "closed pr - pr" "$(run_parked "[{number:30,title:'x',body:'',state:'MERGED',headRefName:'feat/v1-real'}]")" "a parked session with its blocker removed and a merged PR is closed as pr with no launch request"
assert_eq "closed pr - pr" "$(run_parked "[{number:31,title:'x',body:'',state:'OPEN',headRefName:'feat/v1-real'}]")" "an open PR also closes it as pr"
assert_eq "closed pr - pr" "$(run_parked "[{number:32,title:'x',body:'',state:'CLOSED',headRefName:'feat/v1-real'}]")" "a closed PR also closes it as pr"

# --- (3) blocker removed, no PR ----------------------------------------------
assert_eq "closed unparked unpark unparked" "$(run_parked "[]")" "a parked session with its blocker removed and no PR is still unparked"
assert_eq "closed unparked unpark unparked" "$(run_parked "[{number:7,title:'V1 throwaway',body:'Closes #12',state:'OPEN',headRefName:'scratch/other'}]")" "a PR on another branch does not stop the unpark"

# --- blocker still present: stays parked, PR or not --------------------------
printf 'Kind: human-decision\n' > "$TMP/wt/BLOCKER.md"
assert_eq "parked parked - -" "$(run_parked "[{number:30,title:'x',body:'',state:'MERGED',headRefName:'feat/v1-real'}]")" "a parked session whose blocker is still present stays parked"
rm -f "$TMP/wt/BLOCKER.md"

# --- boundary round-trip: saved and reloaded state keeps the closed session --
OUT=$(node - "$SRC" "$STORE" "$TMP" <<'JS'
const r = require(process.argv[2]); const { Store } = require(process.argv[3]); const T = process.argv[4];
const state = { sessions: { 12: { issue: 12, id: 'V1', branch: 'feat/v1-real', status: 'parked', outcome: 'parked', attempt: 1, tier: 'default', worktree: T + '/wt', pid: null } } };
r.reap({ sessionTimeoutMinutes: 120, killGraceSeconds: 60 }, state, [{ number: 30, title: 'x', body: '', state: 'MERGED', headRefName: 'feat/v1-real' }], Date.now(), () => false);
const store = new Store(T + '/state'); store.save(state);
const back = new Store(T + '/state').load().sessions[12];
console.log(back.status, back.outcome);
JS
)
assert_eq "closed pr" "$OUT" "a saved and reloaded state keeps the closed session and its outcome"

finish
