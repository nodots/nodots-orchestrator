#!/usr/bin/env bash
# Fixture test for src/reap.js: one case per row of the classification table.
# classify() is pure over { exitCode, blocker, pr, logEmpty }; blockerFor()
# and prFor() are exercised on real files and a PR list.
set -uo pipefail
cd "$(dirname "$0")"
. ./lib.sh

SRC="$(cd .. && pwd -P)/src/reap.js"
assert_file "$SRC" "reap.js exists"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
TMP=$(cd "$TMP" && pwd -P)

js() { node -e "const r=require('$SRC'); $1"; }
S="{issue:12,id:'T1.2',branch:'feat/t1-2-x',status:'running',attempt:1,tier:'default',worktree:'$TMP/wt'}"

# --- classification table ----------------------------------------------------
assert_eq "pr null" "$(js "const c=r.classify($S,{pr:{number:5,state:'OPEN'},exitCode:0}); console.log(c.outcome, c.next)")" "a PR is movement and asks for nothing"
assert_eq "pr" "$(js "console.log(r.classify($S,{pr:{number:5,state:'OPEN',isDraft:true},exitCode:3}).outcome)")" "a draft PR still counts as the PR (exit code ignored)"
assert_eq "parked null tracked-task" "$(js "const c=r.classify($S,{blocker:{kind:'tracked-task',known:true},exitCode:0}); console.log(c.outcome,c.next,c.kind)")" "a BLOCKER with a known Kind is parked, not relaunched"
assert_eq "parked true" "$(js "const c=r.classify($S,{blocker:{kind:'not-before',known:true,notBefore:'2020-01-01'},exitCode:0}); console.log(c.outcome, c.alarm!==null)")" "a past not-before date raises an alarm while staying parked"
assert_eq "parked false" "$(js "const c=r.classify($S,{blocker:{kind:'human-decision',known:true,notBefore:'2999-01-01'},exitCode:0}); console.log(c.outcome, c.alarm!==null)")" "a future decide-by date raises no alarm"
assert_eq "escalate escalate blocker:none" "$(js "const c=r.classify($S,{blocker:{kind:null,known:false},exitCode:0}); console.log(c.outcome,c.next,c.reason)")" "a BLOCKER without a Kind escalates"
assert_eq "escalate silent" "$(js "const c=r.classify($S,{exitCode:0,logEmpty:false}); console.log(c.outcome,c.reason)")" "exit 0 with nothing to show is silent and escalates"
assert_eq "escalate exit:3" "$(js "const c=r.classify($S,{exitCode:3,logEmpty:false}); console.log(c.outcome,c.reason)")" "a non-zero exit escalates and names the code"
assert_eq "escalate timeout" "$(js "const c=r.classify($S,{exitCode:143,logEmpty:false}); console.log(c.outcome,c.reason)")" "exit 143 is a timeout kill"
assert_eq "escalate exit:unknown" "$(js "const c=r.classify($S,{exitCode:null,logEmpty:false}); console.log(c.outcome,c.reason)")" "a missing exit file with a non-empty log is a failure"
assert_eq "relaunch relaunch" "$(js "const c=r.classify($S,{exitCode:null,logEmpty:true}); console.log(c.outcome,c.next)")" "no exit and an empty log means the process never ran: relaunch, not escalate"
assert_eq "relaunch" "$(js "console.log(r.classify({...$S,status:'launching'},{exitCode:null,logEmpty:false}).outcome)")" "a record still at launching relaunches"

# --- BLOCKER.md discovery and Kind parsing -----------------------------------
mkdir -p "$TMP/wt/.agentic/cells/feat/t1-2-x"
printf '# Blocker: T1.2\n\n- **Bucket:** scope\n- **Kind:** `human-decision`\n- **Reference:** #40\n- **Decide by:** 2999-06-01\n- **One-line ask:** approve the wider lane\n' > "$TMP/wt/.agentic/cells/feat/t1-2-x/BLOCKER.md"
OUT=$(js "const b=r.blockerFor($S); console.log(b.kind, b.known, b.ask, b.notBefore)")
assert_eq "human-decision true approve the wider lane 2999-06-01" "$OUT" "a BLOCKER in the cell directory is found and its Kind, ask and date parsed"
rm -rf "$TMP/wt/.agentic"
printf 'Kind: external\n' > "$TMP/wt/BLOCKER.md"
assert_eq "external true" "$(js "const b=r.blockerFor($S); console.log(b.kind,b.known)")" "a BLOCKER at the worktree root with a bare Kind: line is found"
printf 'Kind: whatever\n' > "$TMP/wt/BLOCKER.md"
assert_eq "whatever false" "$(js "const b=r.blockerFor($S); console.log(b.kind,b.known)")" "an unknown Kind is reported as unknown"
printf 'no kind here\n' > "$TMP/wt/BLOCKER.md"
assert_eq "null false" "$(js "const b=r.blockerFor($S); console.log(b.kind,b.known)")" "a BLOCKER without a Kind line reports null"
rm -f "$TMP/wt/BLOCKER.md"
assert_eq "null" "$(js "console.log(r.blockerFor($S))")" "no BLOCKER.md anywhere reports null"

# --- PR matching: exact head branch only -------------------------------------
PULLS="[{number:1,title:'[READY]: T1.20 other',body:'Closes #120',headRefName:'feat/t1-20'},{number:2,title:'fix stuff',body:'Closes #12',headRefName:'other'},{number:3,title:'[READY]: T1.2 thing',body:'',headRefName:'feat/t1-2-x'}]"
assert_eq "3" "$(js "console.log(r.prFor($S,$PULLS).number)")" "the PR on the package branch wins"
assert_eq "null" "$(js "console.log(r.prFor($S,[{number:1,title:'[READY]: T1.20 other',body:'Closes #120',headRefName:'feat/t1-20'},{number:2,title:'fix stuff',body:'Closes #12',headRefName:'other'}]))")" "without a branch match a closing keyword does not match"
assert_eq "null" "$(js "console.log(r.prFor($S,[{number:9,title:'[READY]: T1.9 other',body:'see also #12 for the follow-up',headRefName:'feat/t1-9'}]))")" "a bare mention of #12 in another PR's body is not a claim"
assert_eq "null" "$(js "console.log(r.prFor($S,[{number:1,title:'[READY]: T1.20 other',body:'Closes #120',headRefName:'feat/t1-20'}]))")" "T1.20 does not satisfy T1.2 (bounded id match, bounded issue ref)"
assert_eq "null" "$(js "console.log(r.prFor($S,[{number:4,title:'[READY]: t1-2 lower-hyphen',body:'',headRefName:'z'}]))")" "a lower-case hyphenated id in the title does not match"

# --- reap over state: exited session with exit file, live session untouched --
mkdir -p "$TMP/logs" "$TMP/wt2"
printf '0\n' > "$TMP/logs/12-1.exit"; printf 'ran\n' > "$TMP/logs/12-1.log"
sleep 300 & LIVE=$!
OUT=$(node - "$SRC" "$TMP" "$LIVE" <<'JS'
const r = require(process.argv[2]); const T = process.argv[3]; const live = Number(process.argv[4]);
const { processStart } = require(require('path').join(require('path').dirname(process.argv[2]), 'exec.js'));
const state = { sessions: {
  12: { issue: 12, id: 'T1.2', branch: 'feat/t1-2-x', status: 'running', attempt: 1, tier: 'default', worktree: T + '/wt', pid: 999999, procStart: null, logPath: T + '/logs/12-1.log', exitPath: T + '/logs/12-1.exit', startedAt: new Date().toISOString() },
  13: { issue: 13, id: 'T1.3', branch: 'feat/t1-3', status: 'running', attempt: 1, tier: 'default', worktree: T + '/wt2', pid: live, procStart: processStart(live), logPath: T + '/logs/13-1.log', exitPath: T + '/logs/13-1.exit', startedAt: new Date().toISOString() },
  14: { issue: 14, id: 'T1.4', branch: 'feat/t1-4', status: 'closed', attempt: 1, tier: 'default', worktree: T + '/none', pid: null },
} };
const out = r.reap({ sessionTimeoutMinutes: 120, killGraceSeconds: 60 }, state, [], Date.now());
console.log(out.live.map(l => l.issue).join(','), out.reaped.map(x => `${x.issue}:${x.outcome}`).join(','), out.requests.map(q => `${q.session.issue}:${q.next}`).join(','));
console.log(state.sessions[12].status, state.sessions[13].status, state.sessions[12].exitCode);
JS
)
kill $LIVE 2>/dev/null; wait $LIVE 2>/dev/null
assert_eq $'13 12:escalate 12:escalate\nclosed running 0' "$OUT" "a dead session is classified and closed, a live one stays running and counts as live, a closed one is skipped"

# --- timeout: SIGTERM first, SIGKILL after the grace period -------------------
# A worker that ignores SIGTERM, so the grace period and the SIGKILL are observable.
bash -c 'trap "" TERM; sleep 300' & VICTIM=$!
sleep 0.2
OUT=$(node - "$SRC" "$TMP" "$VICTIM" <<'JS'
const r = require(process.argv[2]); const T = process.argv[3]; const pid = Number(process.argv[4]);
const { processStart, isAlive } = require(require('path').join(require('path').dirname(process.argv[2]), 'exec.js'));
const started = new Date(Date.now() - 3 * 3600000).toISOString();
const state = { sessions: { 15: { issue: 15, id: 'T1.5', branch: 'b', status: 'running', attempt: 1, tier: 'default', worktree: T, pid, procStart: processStart(pid), logPath: T + '/logs/15-1.log', exitPath: T + '/logs/15-1.exit', startedAt: started } } };
const o1 = r.reap({ sessionTimeoutMinutes: 120, killGraceSeconds: 60 }, state, [], Date.now());
const termSent = Boolean(state.sessions[15].termSentAt);
const t1 = o1.live.length === 1 && o1.live[0].timingOut;
// grace not yet over: still live, no kill
const o2 = r.reap({ sessionTimeoutMinutes: 120, killGraceSeconds: 60 }, state, [], Date.now() + 1000);
// grace over: SIGKILL
state.sessions[15].termSentAt = new Date(Date.now() - 120000).toISOString();
r.reap({ sessionTimeoutMinutes: 120, killGraceSeconds: 60 }, state, [], Date.now());
setTimeout(() => console.log(termSent, t1, o2.live.length, isAlive(pid)), 300);
JS
)
wait $VICTIM 2>/dev/null
assert_eq "true true 1 false" "$OUT" "an over-time session gets SIGTERM and is still live, then SIGKILL once the grace period passes"

finish
