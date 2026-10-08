#!/usr/bin/env bash
# Fixture test for src/report.js: the three outcomes render, the marker makes
# posting idempotent, and the one-line summary names what moved.
set -uo pipefail
cd "$(dirname "$0")"
. ./lib.sh

SRC="$(cd .. && pwd -P)/src/report.js"
assert_file "$SRC" "report.js exists"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

BASE="{cycleId:'c1',at:'2026-10-07T00:00:00Z',dryRun:false,movement:[],counts:{open:5,queued:1,active:2,awaitingReview:1,blocked:0,merged:3,live:2,wipCap:4,wipFree:1},alarms:[],launched:[],reaped:[],escalations:[],parked:[],promoted:[],assigned:[],streak:0,latched:null}"
js() { node -e "const r=require('$SRC'); const base=$BASE; $1"; }

OUT=$(js "console.log(r.summarize({...base,outcome:'movement',movement:[{package:'T1.2',issue:12,artifact:{type:'pr',ref:7}}]}))")
assert_eq "fleet cycle c1: MOVEMENT T1.2 pr:7; streak=0" "$OUT" "movement summary names the package and artifact"
OUT=$(js "console.log(r.summarize({...base,outcome:'exhaustion',streak:2}))")
assert_contains "$OUT" "EXHAUSTION open=5 queued=1 active=2 review=1 blocked=0 merged=3 live=2 free=1" "exhaustion summary carries the live counts"
OUT=$(js "console.log(r.summarize({...base,outcome:'alarm',alarms:[{code:'sync-failed',detail:'x'}],streak:3,latched:{reason:'r'}}))")
assert_contains "$OUT" "ALARM sync-failed" "alarm summary names the alarm code"
assert_contains "$OUT" "LATCHED" "a latched state is visible in the summary"

OUT=$(js "console.log(r.render({...base,outcome:'movement',movement:[{package:'T1.2',issue:12,artifact:{type:'dispatch',ref:'feat/t1-2',detail:'attempt 1'}}],escalations:[{package:'T1.3',n:1,from:'default',to:'strongest',reason:'silent'}],parked:[{id:'T1.4',issue:14,detail:'BLOCKER.md kind=human-decision: approve'}]}))")
assert_contains "$OUT" "<!-- fleet-cycle:c1 -->" "the rendered report starts with the marker"
assert_contains "$OUT" "T1.2 (#12): dispatch feat/t1-2 — attempt 1" "movement rows render"
assert_contains "$OUT" "ESCALATE T1.3 n=1 default->strongest reason=silent" "escalation lines use the pinned progress-log form"
assert_contains "$OUT" "Parked (coordinator decision needed)" "parked packages are called out for the coordinator"
assert_not_contains "$OUT" "dry run" "a real run does not say dry run"
OUT=$(js "console.log(r.render({...base,outcome:'exhaustion',dryRun:true}).split('\n')[0])")
assert_eq "_dry run: nothing was written_" "$OUT" "a dry run says so on its first line"

# --- posting is idempotent on the marker ------------------------------------
OUT=$(js "
const calls=[]; const comments=[];
const tracker={ listComments:()=>({ok:true,comments:comments.map(b=>({body:b}))}), comment:(repo,n,body)=>{calls.push([repo,n]); comments.push(body); return {ok:true,url:'u'};} };
const cfg={repo:'acme/host',epic:1};
const rep={...base,outcome:'exhaustion'};
const a=r.post(tracker,cfg,rep); const b=r.post(tracker,cfg,rep); const c=r.post(tracker,cfg,{...rep,cycleId:'c2'});
console.log(a.ok, a.skipped===undefined, b.ok, b.skipped, c.ok, c.skipped===undefined, calls.length, JSON.stringify(calls[0]))")
assert_eq "true true true true true true 2 [\"acme/host\",1]" "$OUT" "the same cycle posts once; a second cycle posts again; comments go to the epic in the host repo"

OUT=$(js "const tracker={listComments:()=>({ok:false,comments:[]}), comment:()=>({ok:false,error:'boom'})}; console.log(JSON.stringify(r.post(tracker,{repo:'x',epic:1},{...base,outcome:'exhaustion'})))")
assert_eq '{"ok":false,"error":"boom"}' "$OUT" "a failed post reports the error"

finish
