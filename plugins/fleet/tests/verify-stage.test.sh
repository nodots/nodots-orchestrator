#!/usr/bin/env bash
# The verify stage (src/verify.js): for a target with `verify`, the cycle keeps
# one verifier run in flight, hands it the next cell:awaiting-lab PR, and acts
# on each result: a pass stamps and retitles [READY]:, a fail comments and
# re-dispatches the worker at the same tier, a moved head discards the result,
# a lab that was not reverted latches the fleet. Driven end to end through
# `fleet cycle` against a real git remote, the plugin scripts, the gh and
# claude stubs, and the verifier stub (tests/stubs/verifier.js) on loopback.
set -uo pipefail
cd "$(dirname "$0")"
. ./lib.sh

HERE=$(pwd -P)
FLEET="$(cd .. && pwd -P)/bin/fleet.js"
SRC="$(cd .. && pwd -P)/src"
PLUGIN="$(cd ../../agentic-work-packages && pwd -P)"
STAMP="$PLUGIN/skills/agentic-work-packages/assets/scripts/stamp.js"
assert_file "$FLEET" "fleet.js exists"
assert_file "$STAMP" "stamp.js is beside fleet"

TMP=$(mktemp -d)
VPID=""
trap '[ -n "$VPID" ] && kill "$VPID" 2>/dev/null; rm -rf "$TMP"' EXIT
TMP=$(cd "$TMP" && pwd -P)

# --- a real remote and clone --------------------------------------------------
git init -q --bare -b main "$TMP/api.git"
git clone -q "$TMP/api.git" "$TMP/api" 2>/dev/null
git -C "$TMP/api" checkout -q -b main 2>/dev/null || true
git -C "$TMP/api" config user.email f@example.invalid; git -C "$TMP/api" config user.name fixture
printf '# api\n' > "$TMP/api/README.md"
git -C "$TMP/api" add -A && git -C "$TMP/api" commit -qm init && git -C "$TMP/api" push -q -u origin main

# --- stubs -------------------------------------------------------------------
STUB="$TMP/stub"; VDIR="$TMP/verifier"; mkdir -p "$STUB" "$TMP/gh" "$TMP/claude-log" "$VDIR"
cp "$HERE/stubs/gh.js" "$STUB/gh.js"
printf '#!/usr/bin/env bash\nexec node "%s/gh.js" "$@"\n' "$STUB" > "$STUB/gh"; chmod +x "$STUB/gh"
cp "$HERE/stubs/claude.sh" "$STUB/claude"; chmod +x "$STUB/claude"
export GH_STUB_DIR="$TMP/gh" GH_STUB_REMOTE="$TMP/api.git" CLAUDE_STUB_LOG="$TMP/claude-log" CLAUDE_STUB_TARGET="acme/api"
export GH_BIN="$STUB/gh" CLAUDE_BIN="$STUB/claude"
export CLAUDE_CONFIG_FILE="$TMP/claude.json"
node -e "require('fs').writeFileSync('$TMP/claude.json', JSON.stringify({projects:{['$TMP/api']:{hasTrustDialogAccepted:true}}}))"
unset CLAUDECODE

PORT=$(node -e "const s=require('net').createServer().listen(0,'127.0.0.1',()=>{console.log(s.address().port);s.close()})")
export VERIFIER_STUB_DIR="$VDIR" VERIFIER_STUB_PORT="$PORT"
printf '{}' > "$VDIR/script.json"; : > "$VDIR/requests.log"
start_verifier() {
  rm -f "$VDIR/ready"
  node "$HERE/stubs/verifier.js" & VPID=$!
  local i=0; until [ -f "$VDIR/ready" ] || [ $i -ge 40 ]; do sleep 0.25; i=$((i + 1)); done
  [ -f "$VDIR/ready" ]
}
stop_verifier() { kill "$VPID" 2>/dev/null; wait "$VPID" 2>/dev/null; VPID=""; }
# vscript <js mutating s>: edit the verifier stub's script.json
vscript() { node -e "const f='$VDIR/script.json',fs=require('fs');const s=JSON.parse(fs.readFileSync(f,'utf8'));s.refuse=s.refuse||{};s.results=s.results||{};$1;fs.writeFileSync(f,JSON.stringify(s,null,2))"; }
posts() { grep -c ' POST ' "$VDIR/requests.log" || true; }
gets() { grep -c ' GET ' "$VDIR/requests.log" || true; }
requests() { wc -l < "$VDIR/requests.log" | tr -d ' '; }
last_post() { grep ' POST ' "$VDIR/requests.log" | tail -1 | awk '{print $4, $5}'; }

scope_body() { # branch
  printf '**Part of** #1 · **Phase 0 · x** · **Repo:** `acme/api`\n\n## Goal\nx\n\n### SCOPE.json\n```json\n{"feature":"f","branch":"%s","allowedPaths":["src/**"],"forbiddenPaths":[],"dependsOn":[],"execution":{"model":"default","pattern":"solo"}}\n```\n' "$1"
}
node - "$TMP/gh" "$(scope_body feat/t1-1-first)" "$(scope_body feat/v1-gate)" "$(scope_body feat/t1-2-second)" <<'JS'
const fs = require('fs'); const [dir, b10, b11, b12] = process.argv.slice(2);
const q = (number, title, body) => ({ number, title, body, state: 'OPEN', labels: ['agent-ready', 'cell:queued', 'worker:a'] });
fs.writeFileSync(`${dir}/issues.json`, JSON.stringify([
  { number: 1, title: 'Epic: program T', body: '', state: 'OPEN', labels: ['epic'] },
  q(10, 'T1.1 First package', b10), q(11, 'V1 Gate: on the lab', b11), q(12, 'T1.2 Second package', b12),
], null, 2));
fs.writeFileSync(`${dir}/prs.json`, '[]'); fs.writeFileSync(`${dir}/labels.json`, '{}');
fs.writeFileSync(`${dir}/comments.json`, '{}'); fs.writeFileSync(`${dir}/writes.log`, '');
JS

write_config() { # noMovementLimit
  cat > "$TMP/fleet.config.json" <<JSON
{
  "repo": "acme/host", "epic": 1,
  "targets": [{ "repo": "acme/api", "localPath": "$TMP/api", "defaultBranch": "main",
    "ci": { "gate": "external", "verifiedBy": "npm run test:impacted -- --list" },
    "verify": { "kind": "lab-runner", "url": "http://127.0.0.1:$PORT", "suite": "impacted_v2" } }],
  "workers": { "a": { "mode": "local" } },
  "wipCap": 4, "worktreesDir": "$TMP/worktrees", "stateDir": "$TMP/state",
  "pluginRoot": "$PLUGIN", "maxEscalations": 1, "noMovementLimit": $1, "sessionTimeoutMinutes": 5
}
JSON
}
write_config 99
fleet() { node "$FLEET" "$@" --config "$TMP/fleet.config.json"; }
cycle() { OUT=$(fleet cycle --apply --json 2>"$TMP/cycle.err"); EXIT=$?; }
wait_exit() { local f="$TMP/state/logs/$1.exit" i=0; until [ -f "$f" ] || [ $i -ge 60 ]; do sleep 0.5; i=$((i + 1)); done; [ -f "$f" ]; }
st() { node -e "const s=require('$TMP/state/state.json'); const v=(s.verify||{})['acme/api']||{}; console.log(JSON.stringify($1))"; }
pr_field() { node -e "const p=require('$TMP/gh/prs.json').find(x=>x.number===$1); console.log(p.$2)"; }
set_head() { node -e "const f='$TMP/gh/prs.json',fs=require('fs');const a=JSON.parse(fs.readFileSync(f,'utf8'));a.find(x=>x.number===$1).headRefOid='$2';fs.writeFileSync(f,JSON.stringify(a,null,2))"; }
comments_on() { node -e "const c=require('$TMP/gh/comments.json')['$1']||[]; process.stdout.write(c.map(x=>x.body).join('\n<<>>\n'))"; }
ncomments() { node -e "console.log((require('$TMP/gh/comments.json')['$1']||[]).length)"; }
outcome() { printf '%s' "$OUT" | node -e "console.log(JSON.parse(require('fs').readFileSync(0,'utf8')).outcome)"; }
alarm_codes() { printf '%s' "$OUT" | node -e "console.log(JSON.parse(require('fs').readFileSync(0,'utf8')).alarms.map(a=>a.code).join(' '))"; }

# --- setup: three packages, launched one at a time so the PR numbers are fixed
export CLAUDE_STUB_MODE_T1_1=pr CLAUDE_STUB_MODE_V1=pr CLAUDE_STUB_MODE_T1_2=pr
fleet launch 10 --apply >/dev/null 2>&1; wait_exit 10-1
fleet launch 11 --apply >/dev/null 2>&1; wait_exit 11-1
fleet launch 12 --apply >/dev/null 2>&1; wait_exit 12-1
assert_eq "[VERIFY]: T1.1 done|[VERIFY]: V1 done|[VERIFY]: T1.2 done" "$(pr_field 200 title)|$(pr_field 201 title)|$(pr_field 202 title)" "setup: the stub's PR title follows the prompt ([VERIFY]:) and the PRs are #200 T1.1, #201 V1, #202 T1.2"
assert_eq "0" "$(requests)" "setup: fleet launch <issue> runs no verify stage"
H200=$(pr_field 200 headRefOid); H201=$(pr_field 201 headRefOid); H202=$(pr_field 202 headRefOid)
start_verifier && _pass "the verifier stub listens on 127.0.0.1:$PORT" || _fail "the verifier stub listens on 127.0.0.1:$PORT" "no ready file"

# --- dry run: no POST, no comment, no title edit ------------------------------
C0=$(cat "$TMP/gh/comments.json"); W0=$(cat "$TMP/gh/writes.log")
OUT=$(fleet cycle --json 2>/dev/null)
assert_eq "0" "$(posts)" "dry run: no POST to the verifier"
assert_eq "$C0" "$(cat "$TMP/gh/comments.json")" "dry run: nothing written to comments.json"
assert_eq "$W0" "$(cat "$TMP/gh/writes.log")" "dry run: nothing written to writes.log"
assert_contains "$OUT" '"action": "would-post"' "dry run: the report says what it would post"

# --- gate before package --------------------------------------------------------
cycle
assert_eq "1" "$(posts)" "gate first: one POST"
assert_eq "pr=201 202" "$(last_post)" "gate first: the V1 gate PR #201 is posted before the older package PR #200"
assert_eq "{\"pr\":201,\"runId\":\"run-1\",\"headSha\":\"$H201\"}" "$(st '{pr:v.inFlight.pr,runId:v.inFlight.runId,headSha:v.inFlight.headSha}')" "one in flight: state.json holds { pr, runId, headSha } for the target"

# --- one in flight at a time; waiting 4 cycles does not latch ------------------
write_config 3
for i in 1 2 3; do cycle; done
OUT_TEXT=$(fleet cycle --apply 2>/dev/null); EXIT=$?
assert_eq "1" "$(posts)" "one in flight: four more cycles with two PRs waiting send no second POST"
assert_ne "0" "$(gets)" "one in flight: each cycle reads the run instead"
assert_ne "78" "$EXIT" "waiting on a run for 4 cycles does not latch the fleet (noMovementLimit 3)"
assert_eq "null|0" "$(st 's.latched')|$(st 's.streak')" "waiting on a run counts as live: no latch, streak 0"
assert_contains "$OUT_TEXT" "· awaiting-lab 3 · verifying 1" "report: a verify target's counts carry awaiting-lab and verifying"
write_config 99

# --- pass stamps at the run's full sha, on the target repo, and retitles; other 409 comments, skips, moves on
vscript "s.results['201']={finished:true,exitCode:0,reverted:true,tests:[{title:'opens the order',status:'passed',outcome:'expected'},{title:'prints the label',status:'passed',outcome:'flaky'}],selection:{specs:['orders.spec.ts']},deployed:['dbo.usp_Orders.sql']}; s.refuse['200']='PR #200 cannot be verified: it changes dbo.Orders.Table.sql'"
cycle
STAMPC=$(comments_on 'acme/api#201')
assert_eq "VERIFIED: lab-impacted @ $H201" "$(printf '%s' "$STAMPC" | head -1)" "pass: the comment's first line is the stamp at the full 40-hex sha"
assert_eq "0" "$(ncomments 'acme/host#201')" "pass: the stamp goes to the target repo, not the host"
assert_contains "$(cat "$TMP/gh/writes.log")" "comment acme/api 201" "pass: writes.log records the comment on acme/api #201"
assert_contains "$STAMPC" "prints the label" "pass: the summary names the flaky test"
assert_contains "$STAMPC" "orders.spec.ts" "pass: the summary carries verify.selection"
assert_contains "$STAMPC" "dbo.usp_Orders.sql" "pass: the summary carries verify.deployed"
OK=$(node -e "const {currentStamp}=require('$STAMP'); const c=require('$TMP/gh/comments.json')['acme/api#201'].map(x=>x.body); console.log(Boolean(currentStamp({headSha:'$H201',comments:c})))")
assert_eq "true" "$OK" "pass: stamp.js currentStamp accepts the stamp"
assert_eq "[READY]: V1 done" "$(pr_field 201 title)" "pass: the PR is retitled [READY]:"
assert_contains "$(cat "$TMP/gh/writes.log")" "title acme/api 201 [READY]: V1 done" "pass: writes.log records the title edit"
assert_contains "$OUT" '"type": "verified"' "pass: the cycle has a verified movement entry"
assert_contains "$(comments_on 'acme/api#200')" "dbo.Orders.Table.sql" "other 409: the refusal is commented on the PR"
assert_contains "$(alarm_codes)" "verify-refused" "other 409: verify-refused is raised"
assert_eq "\"$H200\"" "$(st 'v.failed[200].headSha')" "other 409: the refusal is recorded at that head"
assert_eq "pr=202 202" "$(last_post)" "other 409: the stage moves on and posts the next PR (#202)"
assert_eq "alarm" "$(outcome)" "verify-refused makes the cycle's outcome alarm"

# --- unreachable alarms and keeps the record --------------------------------------
stop_verifier
cycle
assert_contains "$(alarm_codes)" "verify-unreachable" "unreachable: verify-unreachable is raised"
assert_eq "\"run-2\"" "$(st 'v.inFlight && v.inFlight.runId')" "unreachable: state.json keeps the runId"
assert_eq "alarm" "$(outcome)" "verify-unreachable makes the cycle's outcome alarm"

# --- a moved head discards the result; restarted on the same port, the record resolves
start_verifier && _pass "the verifier stub restarts on the same port" || _fail "the verifier stub restarts on the same port" "no ready file"
NEW202=$(printf 'b%.0s' $(seq 40))
set_head 202 "$NEW202"
vscript "s.results['202']={finished:true,exitCode:0,reverted:true,tests:[]}"
N_POST=$(posts)
cycle
assert_contains "$(alarm_codes)" "verify-stale" "moved head: verify-stale is reported"
assert_eq "null" "$(st 'v.inFlight')" "restart: the next cycle resolves the kept record"
assert_eq "0" "$(ncomments 'acme/api#202')" "moved head: no stamp"
assert_eq "[VERIFY]: T1.2 done" "$(pr_field 202 title)" "moved head: the title stays [VERIFY]:"
assert_ne "alarm" "$(outcome)" "verify-stale alone does not make the outcome alarm"
assert_eq "$N_POST" "$(posts)" "moved head: nothing else is posted this cycle (#200 refused at its head)"
vscript "s.results['202']={finished:true,exitCode:1,reverted:true,tests:[{title:'logs in',status:'failed',outcome:'unexpected'},{title:'logs out',status:'passed',outcome:'expected'}]}"
cycle
assert_eq "pr=202 202" "$(last_post)" "moved head: the next cycle posts the same PR again"

# --- a fail comments, re-dispatches at the same tier with the reason, and skips that head
export CLAUDE_STUB_MODE_T1_2=pr-update CLAUDE_STUB_GATE="$TMP/gate"
cycle
FAILC=$(comments_on 'acme/api#202')
assert_contains "$FAILC" "logs in" "fail: the PR gets a comment carrying the failing test"
assert_eq "" "$(printf '%s\n' "$FAILC" | grep '^VERIFIED' || true)" "fail: the comment has no VERIFIED line"
assert_file "$TMP/claude-log/T1.2.2.argv" "fail: the package's worker is re-dispatched (attempt 2)"
ARGV2=$(cat "$TMP/claude-log/T1.2.2.argv" 2>/dev/null)
assert_contains "$ARGV2" "The previous attempt ended with: verify-failed: logs in" "fail: the worker is told why"
assert_eq "\"verify-failed: logs in\"" "$(st "s.dispatches['T1.2'][1].reason")" "fail: state.dispatches records the reason"
assert_eq "\"default\"|\"default\"" "$(st "s.dispatches['T1.2'][0].tier")|$(st "s.dispatches['T1.2'][1].tier")" "fail: the re-dispatch keeps the tier"
assert_not_contains "$ARGV2" "--model" "fail: the re-dispatch passes no stronger --model"
assert_eq "\"$NEW202\"" "$(st 'v.failed[202].headSha')" "fail: the failure is recorded at that head"
N_POST=$(posts)
cycle
assert_eq "$N_POST" "$(posts)" "fail: the next cycle skips the PR at the failed head"
touch "$TMP/gate"; wait_exit 12-2
assert_ne "$NEW202" "$(pr_field 202 headRefOid)" "pr-update: the second attempt moved the PR head"
assert_eq "$(pr_field 202 headRefOid)" "$(git --git-dir "$TMP/api.git" rev-parse feat/t1-2-second)" "pr-update: the new head is pushed to the branch"
cycle
assert_eq "pr=202 202" "$(last_post)" "fail: once the head changes, the PR is posted again"

# --- at maxEscalations it holds with escalation-cap -------------------------------
cycle
assert_contains "$(alarm_codes)" "escalation-cap" "cap: a second fail at maxEscalations 1 raises escalation-cap"
[ -e "$TMP/claude-log/T1.2.3.argv" ] && _fail "cap: no third attempt is launched" "T1.2.3.argv exists" || _pass "cap: no third attempt is launched"
assert_eq "2" "$(ncomments 'acme/api#202')" "cap: the second fail is still commented"

# --- busy 409 retries next cycle ------------------------------------------------
OTHER200=$(printf 'c%.0s' $(seq 40))
set_head 200 "$OTHER200"
vscript "delete s.refuse['200']; s.results['999']={finished:false}; s.results['200']={finished:false}"
node -e "const r=require('http').request({host:'127.0.0.1',port:$PORT,method:'POST',path:'/impacted_v2/verify',headers:{'content-type':'application/json'}},x=>{x.resume();x.on('end',()=>process.exit(x.statusCode===202?0:1))});r.end(JSON.stringify({pr:999}))" \
  && _pass "busy: another session's run is going" || _fail "busy: another session's run is going" "foreign POST refused"
N200=$(ncomments 'acme/api#200')
cycle
assert_eq "pr=200 409" "$(last_post)" "busy: the head-changed PR #200 is posted and answered busy"
assert_eq "null" "$(st 'v.inFlight')" "busy: nothing is recorded in flight"
assert_eq "$N200" "$(ncomments 'acme/api#200')" "busy: no comment on the PR"
assert_not_contains "$(alarm_codes)" "verify-refused" "busy: a busy 409 is not a refusal"
assert_contains "$OUT" '"action": "busy"' "busy: the report says the verifier was busy"
vscript "s.results['999'].finished=true"
cycle
assert_eq "pr=200 202" "$(last_post)" "busy: the next cycle posts it again and it starts"

# --- reverted: false latches the fleet; fleet resume clears it -----------------
vscript "s.results['200']={finished:true,exitCode:0,reverted:false,tests:[]}"
cycle
assert_contains "$(alarm_codes)" "verify-not-reverted" "not reverted: verify-not-reverted is raised"
assert_eq "alarm" "$(outcome)" "verify-not-reverted makes the cycle's outcome alarm"
assert_contains "$(st 's.latched && s.latched.reason')" "verify-not-reverted" "not reverted: the fleet is latched with that reason"
assert_eq "" "$(comments_on 'acme/api#200' | grep '^VERIFIED' || true)" "not reverted: no stamp"
N_REQ=$(requests)
cycle
assert_eq "78" "$EXIT" "not reverted: the next applied cycle refuses (exit 78)"
assert_eq "$N_REQ" "$(requests)" "not reverted: a latched cycle makes no POST or GET with a PR waiting"
fleet resume --reason x >/dev/null 2>&1
vscript "s.results['200']={finished:true,exitCode:0,reverted:true,headSha:'abc1234',tests:[]}"
cycle
assert_eq "pr=200 202" "$(last_post)" "not reverted: after fleet resume the next cycle posts"

# --- a non-hex or short sha is not stamped ------------------------------------------
cycle
assert_contains "$(alarm_codes)" "verify-bad-sha" "bad sha: verify-bad-sha is raised"
assert_eq "" "$(comments_on 'acme/api#200' | grep '^VERIFIED' || true)" "bad sha: no stamp"
assert_eq "alarm" "$(outcome)" "verify-bad-sha makes the cycle's outcome alarm"
assert_eq "[VERIFY]: T1.1 done" "$(pr_field 200 title)" "bad sha: the title stays [VERIFY]:"

# --- a [READY]: PR pushed after its stamp is retitled [VERIFY]: and queued again ----
NEW201=$(printf 'd%.0s' $(seq 40))
set_head 201 "$NEW201"
cycle
assert_eq "[VERIFY]: V1 done" "$(pr_field 201 title)" "push after READY: the PR is retitled [VERIFY]:"
assert_contains "$(cat "$TMP/gh/writes.log")" "title acme/api 201 [VERIFY]: V1 done" "push after READY: writes.log records the retitle"
cycle
assert_contains "$(node -e "console.log((require('$TMP/gh/labels.json')[11]||[]).join(' '))")" "cell:awaiting-lab" "push after READY: sync derives cell:awaiting-lab"
assert_eq "pr=201 202" "$(last_post)" "push after READY: the PR is queued and posted again"

# --- a config without verify renders the report byte for byte as before --------
GOLDEN='"<!-- fleet-cycle:c1 -->\n## fleet cycle c1 — EXHAUSTION\n\n_2026-11-02T00:00:00Z_\n\n**Counts** (read live at the end of the cycle)\nopen 5 · queued 1 · active 2 · awaiting-review 1 · blocked 0 · merged 3 · live sessions 2 · WIP free 1/4\n\n**Alarms**\n- wip-cap (#12): T1.2 waits\n\nstreak 1"'
GOLDEN_SUM='"fleet cycle c1: EXHAUSTION open=5 queued=1 active=2 review=1 blocked=0 merged=3 live=2 free=1; streak=1"'
REND=$(node -e "
const report=require('$SRC/report.js'); const { counts }=require('$SRC/cycle.js');
const L=(n,l)=>({number:n,state:'OPEN',labels:[l]});
const issues=[{number:1,state:'OPEN',labels:['cell:queued','worker:a']},L(2,'cell:active'),L(3,'cell:active'),L(4,'cell:awaiting-review'),{number:5,state:'OPEN',labels:[]},{number:6,state:'CLOSED',labels:['cell:merged']},{number:7,state:'CLOSED',labels:['cell:merged']},{number:8,state:'CLOSED',labels:['cell:merged']}];
const c=counts(issues,null,{length:2},{wipCap:4,targets:[{repo:'acme/api'}]},0);
const rep={cycleId:'c1',at:'2026-11-02T00:00:00Z',dryRun:false,outcome:'exhaustion',movement:[],counts:c,alarms:[{code:'wip-cap',detail:'T1.2 waits',issue:12}],launched:[],reaped:[],escalations:[],parked:[],promoted:[],assigned:[],verify:[],streak:1,latched:null};
console.log(JSON.stringify(report.render(rep))); console.log(JSON.stringify(report.summarize(rep)));")
assert_eq "$GOLDEN" "$(printf '%s\n' "$REND" | sed -n 1p)" "no verify: the rendered report is byte-identical to origin/development"
assert_eq "$GOLDEN_SUM" "$(printf '%s\n' "$REND" | sed -n 2p)" "no verify: the summary line is byte-identical to origin/development"

finish
