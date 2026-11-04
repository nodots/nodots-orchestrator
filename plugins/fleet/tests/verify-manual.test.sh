#!/usr/bin/env bash
# verify.kind "manual" (src/verify.js): the verifier is a person or a script
# outside fleet. The target keeps the [VERIFY]: worker contract and the
# cell:awaiting-lab queue; the stage lists the queue (gates first, then oldest)
# in the report and makes no request, raises no alarm, and its waiting PRs keep
# the no-movement streak from latching. A PR someone else stamps at its head
# and retitles [READY]: leaves the queue. Driven end to end through `fleet
# cycle` against a real git remote, the plugin scripts and the gh and claude stubs.
set -uo pipefail
cd "$(dirname "$0")"
. ./lib.sh

HERE=$(pwd -P)
FLEET="$(cd .. && pwd -P)/bin/fleet.js"
SRC="$(cd .. && pwd -P)/src"
PLUGIN="$(cd ../../agentic-work-packages && pwd -P)"
assert_file "$FLEET" "fleet.js exists"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
TMP=$(cd "$TMP" && pwd -P)

# --- a real remote and clone --------------------------------------------------
git init -q --bare -b main "$TMP/api.git"
git clone -q "$TMP/api.git" "$TMP/api" 2>/dev/null
git -C "$TMP/api" checkout -q -b main 2>/dev/null || true
git -C "$TMP/api" config user.email f@example.invalid; git -C "$TMP/api" config user.name fixture
printf '# api\n' > "$TMP/api/README.md"
git -C "$TMP/api" add -A && git -C "$TMP/api" commit -qm init && git -C "$TMP/api" push -q -u origin main
fixture_standards "$TMP/api" && git -C "$TMP/api" push -q origin main

# --- stubs -------------------------------------------------------------------
STUB="$TMP/stub"; mkdir -p "$STUB" "$TMP/gh" "$TMP/claude-log"
cp "$HERE/stubs/gh.js" "$STUB/gh.js"
printf '#!/usr/bin/env bash\nexec node "%s/gh.js" "$@"\n' "$STUB" > "$STUB/gh"; chmod +x "$STUB/gh"
cp "$HERE/stubs/claude.sh" "$STUB/claude"; chmod +x "$STUB/claude"
export GH_STUB_DIR="$TMP/gh" GH_STUB_REMOTE="$TMP/api.git" CLAUDE_STUB_LOG="$TMP/claude-log" CLAUDE_STUB_TARGET="acme/api"
export GH_BIN="$STUB/gh" CLAUDE_BIN="$STUB/claude"
export CLAUDE_CONFIG_FILE="$TMP/claude.json"
node -e "require('fs').writeFileSync('$TMP/claude.json', JSON.stringify({projects:{['$TMP/api']:{hasTrustDialogAccepted:true}}}))"
unset CLAUDECODE

scope_body() { # branch
  printf '**Part of** #1 · **Phase 0 · x** · **Repo:** `acme/api`\n\n## Goal\nx\n\n### SCOPE.json\n```json\n{"feature":"f","branch":"%s","allowedPaths":["src/**"],"forbiddenPaths":[],"dependsOn":[],"execution":{"model":"default","pattern":"solo"}}\n```\n' "$1"
}
node - "$TMP/gh" "$(scope_body feat/t1-1-first)" "$(scope_body feat/v1-gate)" <<'JS'
const fs = require('fs'); const [dir, b10, b11] = process.argv.slice(2);
const q = (number, title, body) => ({ number, title, body, state: 'OPEN', labels: ['agent-ready', 'cell:queued', 'worker:a'] });
fs.writeFileSync(`${dir}/issues.json`, JSON.stringify([
  { number: 1, title: 'Epic: program T', body: '', state: 'OPEN', labels: ['epic'] },
  q(10, 'T1.1 First package', b10), q(11, 'V1 Gate: on the lab', b11),
], null, 2));
fs.writeFileSync(`${dir}/prs.json`, '[]'); fs.writeFileSync(`${dir}/labels.json`, '{}');
fs.writeFileSync(`${dir}/comments.json`, '{}'); fs.writeFileSync(`${dir}/writes.log`, '');
JS

write_config() { # noMovementLimit
  cat > "$TMP/fleet.config.json" <<JSON
{
  "repo": "acme/host", "epic": 1,
  "targets": [{ "repo": "acme/api", "localPath": "$TMP/api", "defaultBranch": "main",
    "ci": { "gate": "external", "verifiedBy": "the release engineer runs the lab suite by hand" },
    "verify": { "kind": "manual" } }],
  "workers": { "a": { "mode": "local" } },
  "wipCap": 4, "worktreesDir": "$TMP/worktrees", "stateDir": "$TMP/state",
  "pluginRoot": "$PLUGIN", "noMovementLimit": $1, "sessionTimeoutMinutes": 5
}
JSON
}
write_config 99
fleet() { node "$FLEET" "$@" --config "$TMP/fleet.config.json"; }
cycle() { OUT=$(fleet cycle --apply --json 2>"$TMP/cycle.err"); EXIT=$?; }
wait_exit() { local f="$TMP/state/logs/$1.exit" i=0; until [ -f "$f" ] || [ $i -ge 60 ]; do sleep 0.5; i=$((i + 1)); done; [ -f "$f" ]; }
st() { node -e "const s=require('$TMP/state/state.json'); console.log(JSON.stringify($1))"; }
pr_field() { node -e "const p=require('$TMP/gh/prs.json').find(x=>x.number===$1); console.log(p.$2)"; }
set_title() { node -e "const f='$TMP/gh/prs.json',fs=require('fs');const a=JSON.parse(fs.readFileSync(f,'utf8'));a.find(x=>x.number===$1).title='$2';fs.writeFileSync(f,JSON.stringify(a,null,2))"; }
add_comment() { node -e "const f='$TMP/gh/comments.json',fs=require('fs');const a=JSON.parse(fs.readFileSync(f,'utf8'));(a['$1']=a['$1']||[]).push({id:9000+(a['$1'].length),body:process.argv[1],created_at:'2026-11-02T00:00:00Z'});fs.writeFileSync(f,JSON.stringify(a,null,2))" "$2"; }
ncomments() { node -e "console.log((require('$TMP/gh/comments.json')['$1']||[]).length)"; }
alarm_codes() { printf '%s' "$OUT" | node -e "console.log(JSON.parse(require('fs').readFileSync(0,'utf8')).alarms.map(a=>a.code).join(' '))"; }
queue() { printf '%s' "$OUT" | node -e "console.log(JSON.parse(require('fs').readFileSync(0,'utf8')).verify.filter(v=>v.action==='queued').map(v=>v.pr).join(' ')||'none')"; }
labels_of() { node -e "console.log((require('$TMP/gh/labels.json')[$1]||[]).join(' '))"; }

# --- config: manual needs no url or suite; a url is refused --------------------
CFG=$(node -e "const {validate}=require('$SRC/config.js'); const t=validate({repo:'acme/host',epic:1,workers:{a:{mode:'local'}},pluginRoot:'$PLUGIN',targets:[{repo:'acme/api',localPath:'.',ci:{gate:'external',verifiedBy:'x'},verify:{kind:'manual'}}]},'$TMP').targets[0]; console.log(JSON.stringify(t.verify))" 2>&1)
assert_eq '{"kind":"manual"}' "$CFG" "config: verify {kind: manual} is accepted with no url or suite"
BAD=$(node -e "const {validate}=require('$SRC/config.js'); try { validate({repo:'acme/host',epic:1,workers:{a:{mode:'local'}},pluginRoot:'$PLUGIN',targets:[{repo:'acme/api',localPath:'.',ci:{gate:'external',verifiedBy:'x'},verify:{kind:'manual',url:'http://127.0.0.1:1'}}]},'$TMP'); console.log('accepted') } catch (e) { console.log(e.message) }")
assert_contains "$BAD" "verify.url" "config: a manual target with a url is refused (it is never requested)"
LAB=$(node -e "const {validate}=require('$SRC/config.js'); try { validate({repo:'acme/host',epic:1,workers:{a:{mode:'local'}},pluginRoot:'$PLUGIN',targets:[{repo:'acme/api',localPath:'.',ci:{gate:'external',verifiedBy:'x'},verify:{kind:'lab-runner'}}]},'$TMP'); console.log('accepted') } catch (e) { console.log(e.message) }")
assert_contains "$LAB" "verify.url" "config: lab-runner still requires a url"

# --- setup: two packages, launched one at a time so the PR numbers are fixed ---
export CLAUDE_STUB_MODE_T1_1=pr CLAUDE_STUB_MODE_V1=pr
fleet launch 10 --apply >/dev/null 2>&1; wait_exit 10-1
fleet launch 11 --apply >/dev/null 2>&1; wait_exit 11-1
assert_eq "[VERIFY]: T1.1 done|[VERIFY]: V1 done" "$(pr_field 200 title)|$(pr_field 201 title)" "setup: the worker prompt carries [VERIFY]: for a manual target; PRs #200 T1.1 and #201 V1"
H201=$(pr_field 201 headRefOid)

# --- two [VERIFY] PRs: no request, no alarm, both reported in queue order ------
cycle
assert_eq "201 200" "$(queue)" "queue: both PRs are reported, the V1 gate (#201) before the older package (#200)"
assert_eq "" "$(alarm_codes)" "queue: no alarm is raised"
assert_not_contains "$OUT" '"verify-unreachable"' "queue: no verify-unreachable"
assert_eq "{}" "$(st 's.verify && s.verify["acme/api"] ? s.verify["acme/api"].inFlight || {} : {}')" "queue: nothing is recorded in flight"
assert_eq "0|0" "$(ncomments 'acme/api#200')|$(ncomments 'acme/api#201')" "queue: no comment is posted on either PR"
OUT_TEXT=$(fleet cycle 2>/dev/null)
assert_contains "$OUT_TEXT" "acme/api#201: queued" "report: the text report lists #201"
assert_contains "$OUT_TEXT" "acme/api#200: queued" "report: the text report lists #200"
assert_contains "$OUT_TEXT" "· awaiting-lab 2 · verifying 0" "report: the counts carry awaiting-lab 2"

# --- no HTTP request at all: stage() over a fake http that records every call ---
UNIT=$(node -e "
const verify=require('$SRC/verify.js');
const H='e'.repeat(40);
const cfg={scriptsDir:'$PLUGIN/skills/agentic-work-packages/assets/scripts',targets:[{repo:'acme/api',verify:{kind:'manual'}}]};
const pr=(number,title)=>({number,title,state:'OPEN',headSha:H,comments:[]});
const sync={rows:[{number:10,to:'cell:awaiting-lab'},{number:11,to:'cell:awaiting-lab'}],state:{issues:[{number:10,title:'T1.1 x',repo:'acme/api',pr:pr(200,'[VERIFY]: T1.1')},{number:11,title:'V1 Gate',repo:'acme/api',pr:pr(201,'[VERIFY]: V1')}]}};
const pulls=[{number:200,repo:'acme/api',state:'OPEN',title:'[VERIFY]: T1.1',headRefOid:H},{number:201,repo:'acme/api',state:'OPEN',title:'[VERIFY]: V1',headRefOid:H}];
const calls=[]; const alarms=[]; const writes=[];
const tracker={prComment:()=>{writes.push('c');return{ok:true}},editPrTitle:()=>{writes.push('t');return{ok:true}}};
const r={verify:[],movement:[]};
const state={sessions:{}};
const out=verify.stage({cfg,state,apply:true,tracker,pulls,pullsFailed:new Set(),sync,issues:[],at:'now',alarm:c=>alarms.push(c),r,http:(...a)=>{calls.push(a);return{ok:false,error:'no'}}});
const lab={targets:[{repo:'acme/api',verify:{kind:'lab-runner',url:'http://127.0.0.1:1',suite:'s'}}]};
if (verify.manualWaiting(cfg,sync)!==2 || verify.manualWaiting(lab,sync)!==0) { console.log('manualWaiting wrong'); process.exit(0); }
console.log([calls.length===0, alarms.length===0, writes.length===0, out.verifying===0, out.waiting===2, r.verify.map(v=>v.pr).join(',')==='201,200'].join(' '));")
assert_eq "true true true true true true" "$UNIT" "unit: a manual target makes no http call, no alarm, no write; verifying 0, waiting 2, queue order 201,200; manualWaiting (the fleet launch path) counts 2, and 0 for lab-runner"

# --- only waiting manual PRs and no live workers: 4 applied cycles do not latch ---
write_config 3
OUTCOMES=""
for i in 1 2 3; do cycle; OUTCOMES="$OUTCOMES$(printf '%s' "$OUT" | node -e "console.log(JSON.parse(require('fs').readFileSync(0,'utf8')).outcome)") "; done
assert_eq "exhaustion exhaustion exhaustion " "$OUTCOMES" "streak: the waiting cycles have no movement (outcome exhaustion)"
OUT_TEXT=$(fleet cycle --apply 2>/dev/null); EXIT=$?
assert_ne "78" "$EXIT" "streak: 4 applied cycles with only waiting manual PRs do not latch (noMovementLimit 3)"
assert_eq "null" "$(st 's.latched')" "streak: state.latched is null"
assert_eq "0" "$(st 's.streak')" "streak: waiting on a manual verifier holds the streak at 0"
assert_eq "0" "$(node -e "const s=require('$TMP/state/state.json'); console.log(Object.values(s.sessions).filter(x=>x.status!=='closed').length)")" "streak: no live worker session"
write_config 99

# --- someone else stamps #201 at its head and retitles [READY]: it leaves the queue
add_comment 'acme/api#201' "VERIFIED: manual-lab @ $H201

run by hand"
set_title 201 '[READY]: V1 done'
cycle
assert_eq "200" "$(queue)" "stamped and retitled by someone else: #201 leaves the queue, #200 stays"
assert_eq "[READY]: V1 done" "$(pr_field 201 title)" "stamped and retitled: the title is left [READY]:"
assert_not_contains "$(labels_of 11)" "cell:awaiting-lab" "stamped and retitled: sync no longer derives cell:awaiting-lab for V1"
assert_not_contains "$(cat "$TMP/gh/writes.log")" "title acme/api 201" "stamped and retitled: fleet writes no title on #201"
assert_eq "" "$(alarm_codes)" "stamped and retitled: no alarm"

# --- someone else stamps #200 at its head without retitling: the stage retitles it
H200=$(pr_field 200 headRefOid)
add_comment 'acme/api#200' "VERIFIED: manual-lab @ $H200"
cycle
assert_eq "[READY]: T1.1 done" "$(pr_field 200 title)" "stamped, not retitled: the stage retitles #200 [READY]: as for lab-runner"
assert_eq "none" "$(queue)" "stamped, not retitled: the queue is empty"

finish
