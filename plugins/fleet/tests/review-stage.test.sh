#!/usr/bin/env bash
# The review stage (src/review.js): for a target whose standards manifest has a
# `review` policy, the cycle launches the configured reviewers, one per
# cell:awaiting-reviewer PR, each read-only in a fresh worktree at the PR head,
# and acts on each verdict: a pass posts REVIEWED: <name> @ <head>, a fail
# comments the findings and re-dispatches the worker at the same tier; invalid
# output, a timeout, a moved head or a reviewer that wrote to its worktree is an
# alarm and stamps nothing. Driven end to end through `fleet cycle` against a
# real git remote, the plugin scripts, the gh and claude stubs, and the
# reviewer stub (tests/stubs/reviewer.sh).
set -uo pipefail
cd "$(dirname "$0")"
. ./lib.sh

HERE=$(pwd -P)
FLEET="$(cd .. && pwd -P)/bin/fleet.js"
SRC="$(cd .. && pwd -P)/src"
PLUGIN="$(cd ../../agentic-work-packages && pwd -P)"
assert_file "$FLEET" "fleet.js exists"
assert_file "$SRC/review.js" "review.js exists"

TMP=$(mktemp -d)
trap 'touch "$TMP/gate" 2>/dev/null; rm -rf "$TMP"' EXIT
TMP=$(cd "$TMP" && pwd -P)

# --- config: reviewers ----------------------------------------------------------
js() { node -e "const c=require('$SRC/config.js'); $1" 2>&1; }
mkdir -p "$TMP/p/.claude-plugin"; printf '{"name":"x"}' > "$TMP/p/.claude-plugin/plugin.json"
BASE="{repo:'acme/host',epic:1,targets:[{repo:'api',localPath:'./api'}],workers:{a:{mode:'local'}},pluginRoot:'$TMP/p'}"
assert_eq "[]" "$(js "console.log(JSON.stringify(c.validate($BASE,'$TMP').reviewers))")" "config without reviewers: reviewers is []"
assert_eq '[{"name":"r.1","argv":["x","{prompt}"],"timeoutMinutes":20}]' "$(js "console.log(JSON.stringify(c.validate({...$BASE,reviewers:[{name:'r.1',argv:['x','{prompt}']}]},'$TMP').reviewers))")" "reviewers: timeoutMinutes defaults to 20"
for bad in "{name:'bad name',argv:['x']}" "{name:'r',argv:[]}" "{name:'r',argv:['x',3]}" "{name:'r',argv:'x {prompt}'}" "{name:'r',argv:['x'],timeoutMinutes:0}" "{argv:['x']}"; do
  assert_eq "ECONFIG" "$(js "try{c.validate({...$BASE,reviewers:[$bad]},'$TMP');console.log('accepted')}catch(e){console.log(e.code)}")" "reviewers rejected: $bad"
done
assert_eq "ECONFIG" "$(js "try{c.validate({...$BASE,reviewers:{}},'$TMP');console.log('accepted')}catch(e){console.log(e.code)}")" "reviewers rejected: not an array"
assert_eq "ECONFIG" "$(js "try{c.validate({...$BASE,reviewers:[{name:'r',argv:['x']},{name:'r',argv:['y']}]},'$TMP');console.log('accepted')}catch(e){console.log(e.code)}")" "reviewers rejected: a duplicate name"
OUT=$(js "try{c.requireReviewers(c.validate($BASE,'$TMP'),{'acme/api':{passes:1}});console.log('accepted')}catch(e){console.log(e.code, e.message)}")
assert_contains "$OUT" "ECONFIG" "a review-policy target with no reviewers fails validation"
assert_contains "$OUT" "acme/api" "the failure names the target"
assert_eq "accepted" "$(js "try{c.requireReviewers(c.validate($BASE,'$TMP'),{'acme/api':null});console.log('accepted')}catch(e){console.log(e.message)}")" "a target without a policy needs no reviewers"
assert_eq "accepted" "$(js "try{c.requireReviewers(c.validate($BASE,'$TMP'),{});console.log('accepted')}catch(e){console.log(e.message)}")" "a config without either is unchanged"
assert_eq "undefined|undefined" "$(node -e "const {counts}=require('$SRC/cycle.js'); const c=counts([], {}, [], {wipCap:2,targets:[{repo:'acme/api'}],reviewers:[]}); console.log(c.awaitingReviewer+'|'+c.reviewing)")" "counts: no reviewers configured, no review counts"

# --- a real remote and clone, with a review policy -------------------------------
git init -q --bare -b main "$TMP/api.git"
git clone -q "$TMP/api.git" "$TMP/api" 2>/dev/null
git -C "$TMP/api" checkout -q -b main 2>/dev/null || true
git -C "$TMP/api" config user.email f@example.invalid; git -C "$TMP/api" config user.name fixture
printf '# api\n' > "$TMP/api/README.md"
git -C "$TMP/api" add -A && git -C "$TMP/api" commit -qm init && git -C "$TMP/api" push -q -u origin main
fixture_standards "$TMP/api"
printf '{"version": 1, "checks": [{"name": "test", "command": "true"}], "rules": [], "review": {"passes": 1}}\n' > "$TMP/api/.claude/standards.json"
git -C "$TMP/api" commit -qam "fixture: review policy" && git -C "$TMP/api" push -q origin main

# --- stubs -------------------------------------------------------------------
STUB="$TMP/stub"; RLOG="$TMP/reviewer-log"; mkdir -p "$STUB" "$TMP/gh" "$TMP/claude-log"
cp "$HERE/stubs/gh.js" "$STUB/gh.js"
printf '#!/usr/bin/env bash\nexec node "%s/gh.js" "$@"\n' "$STUB" > "$STUB/gh"; chmod +x "$STUB/gh"
cp "$HERE/stubs/claude.sh" "$STUB/claude"; chmod +x "$STUB/claude"
cp "$HERE/stubs/reviewer.sh" "$STUB/reviewer"; chmod +x "$STUB/reviewer"
export GH_STUB_DIR="$TMP/gh" GH_STUB_REMOTE="$TMP/api.git" CLAUDE_STUB_LOG="$TMP/claude-log" CLAUDE_STUB_TARGET="acme/api"
export GH_BIN="$STUB/gh" CLAUDE_BIN="$STUB/claude" REVIEWER_STUB_LOG="$RLOG" REVIEWER_STUB_GATE="$TMP/gate"
export CLAUDE_CONFIG_FILE="$TMP/claude.json"
node -e "require('fs').writeFileSync('$TMP/claude.json', JSON.stringify({projects:{['$TMP/api']:{hasTrustDialogAccepted:true}}}))"
unset CLAUDECODE

# Seven packages, T1.1..T1.7 (#10..#16), whose PRs are #200..#206.
scope_body() { # branch id
  printf '**Part of** #1 · **Phase 0 · x** · **Repo:** `acme/api`\n\n## Goal\nGoal of %s: make the widget count.\n\n### SCOPE.json\n```json\n{"feature":"f","branch":"%s","allowedPaths":["src/**"],"forbiddenPaths":[],"dependsOn":[],"execution":{"model":"default","pattern":"solo"}}\n```\n' "$2" "$1"
}
node - "$TMP/gh" $(for k in 1 2 3 4 5 6 7; do printf '%s ' "$(scope_body "feat/t1-$k" "T1.$k" | base64 -w0)"; done) <<'JS'
const fs = require('fs'); const [dir, ...bodies] = process.argv.slice(2);
const q = (k, body) => ({ number: 9 + k, title: `T1.${k} Package ${k}`, body: Buffer.from(body, 'base64').toString(), state: 'OPEN', labels: ['agent-ready', 'cell:queued', 'worker:a'] });
fs.writeFileSync(`${dir}/issues.json`, JSON.stringify([
  { number: 1, title: 'Epic: program T', body: '', state: 'OPEN', labels: ['epic'] },
  ...bodies.map((b, i) => q(i + 1, b)),
], null, 2));
fs.writeFileSync(`${dir}/prs.json`, '[]'); fs.writeFileSync(`${dir}/labels.json`, '{}');
fs.writeFileSync(`${dir}/comments.json`, '{}'); fs.writeFileSync(`${dir}/writes.log`, '');
JS

write_config() { # reviewers-json
  cat > "$TMP/fleet.config.json" <<JSON
{
  "repo": "acme/host", "epic": 1,
  "targets": [{ "repo": "acme/api", "localPath": "$TMP/api", "defaultBranch": "main" }],
  "workers": { "a": { "mode": "local" } },
  "wipCap": 8, "worktreesDir": "$TMP/worktrees", "stateDir": "$TMP/state",
  "pluginRoot": "$PLUGIN", "maxEscalations": 1, "noMovementLimit": 1, "sessionTimeoutMinutes": 5
  $1
}
JSON
}
write_config ""
fleet() { node "$FLEET" "$@" --config "$TMP/fleet.config.json"; }
cycle() { OUT=$(fleet cycle --apply --json 2>"$TMP/cycle.err"); EXIT=$?; }
wait_exit() { local f="$TMP/state/logs/$1.exit" i=0; until [ -f "$f" ] || [ $i -ge 60 ]; do sleep 0.5; i=$((i + 1)); done; [ -f "$f" ]; }
st() { node -e "const s=require('$TMP/state/state.json'); const v=(s.review||{})['acme/api']||{}; console.log(JSON.stringify($1))"; }
pr_field() { node -e "const p=require('$TMP/gh/prs.json').find(x=>x.number===$1); console.log(p.$2)"; }
set_head() { node -e "const f='$TMP/gh/prs.json',fs=require('fs');const a=JSON.parse(fs.readFileSync(f,'utf8'));a.find(x=>x.number===$1).headRefOid='$2';fs.writeFileSync(f,JSON.stringify(a,null,2))"; }
add_comment() { node -e "const f='$TMP/gh/comments.json',fs=require('fs');const a=JSON.parse(fs.readFileSync(f,'utf8'));const k='acme/api#$1';a[k]=[...(a[k]||[]),{id:Date.now(),body:process.argv[1],created_at:new Date().toISOString()}];fs.writeFileSync(f,JSON.stringify(a,null,2))" "$2"; }
comments_on() { node -e "const c=require('$TMP/gh/comments.json')['acme/api#$1']||[]; process.stdout.write(c.map(x=>x.body).join('\n<<>>\n'))"; }
first_lines() { node -e "const c=require('$TMP/gh/comments.json')['acme/api#$1']||[]; console.log(c.map(x=>x.body.split('\n')[0]).join('|'))"; }
jq_out() { printf '%s' "$OUT" | node -e "const r=JSON.parse(require('fs').readFileSync(0,'utf8')); console.log($1)"; }
alarm_codes() { jq_out "r.alarms.map(a=>a.code).join(' ')"; }
alarm_detail() { jq_out "r.alarms.filter(a=>a.code==='$1').map(a=>a.detail).join(' | ')"; }
labels_of() { node -e "console.log((require('$TMP/gh/labels.json')[$1]||[]).join(' '))"; }
argv_count() { compgen -G "$RLOG/$1.*.argv" | wc -l | tr -d ' '; }

# --- setup: seven PRs, each with a current VERIFIED stamp -----------------------
for k in 1 2 3 4 5 6 7; do export "CLAUDE_STUB_MODE_T1_$k=pr"; done
for k in 1 2 3 4 5 6 7; do fleet launch $((9 + k)) --apply >/dev/null 2>&1; wait_exit "$((9 + k))-1"; done
assert_eq "[READY]: T1.1 done|[READY]: T1.7 done" "$(pr_field 200 title)|$(pr_field 206 title)" "setup: PRs #200 (T1.1) .. #206 (T1.7)"
for n in 200 201 202 203 204 205 206; do add_comment $n "VERIFIED: test @ $(pr_field $n headRefOid)

test: true
ok"; done
H200=$(pr_field 200 headRefOid); H201=$(pr_field 201 headRefOid)
for k in 1 2 3 4 5 6 7; do export "CLAUDE_STUB_MODE_T1_$k=silent"; done

# --- a review policy and no reviewers: validation fails, naming the target --------
cycle
assert_eq "64" "$EXIT" "no reviewers: the cycle exits 64 (usage), as a config that fails validation"
assert_contains "$(alarm_codes)" "config-invalid" "no reviewers: alarm config-invalid"
assert_contains "$(alarm_detail config-invalid)" "acme/api" "no reviewers: the alarm names the target"
assert_eq "0" "$(jq_out 'r.launched.length')" "no reviewers: nothing launches"
assert_contains "$(labels_of 10)" "cell:awaiting-reviewer" "sync: a verified PR under a review policy is cell:awaiting-reviewer"

write_config ", \"reviewers\": [{ \"name\": \"stub-a\", \"argv\": [\"$STUB/reviewer\", \"{prompt}\", \"{worktree}\", \"{out}\"] }]"
export REVIEWER_STUB_VERDICT_200=pass REVIEWER_STUB_VERDICT_201=fail REVIEWER_STUB_VERDICT_202=invalid REVIEWER_STUB_VERDICT_203=write REVIEWER_STUB_VERDICT_204=commit REVIEWER_STUB_VERDICT_205=sleep REVIEWER_STUB_VERDICT_206=sleep

# --- dry run: no spawn, no comment, no stamp, no worktree ------------------------
C0=$(cat "$TMP/gh/comments.json"); W0=$(cat "$TMP/gh/writes.log")
OUT=$(fleet cycle --json 2>/dev/null)
TEXT=$(fleet cycle 2>/dev/null)
sleep 1
assert_eq "0" "$(compgen -G "$RLOG/*.argv" | wc -l | tr -d ' ')" "dry run: no reviewer is spawned"
assert_eq "$C0|$W0" "$(cat "$TMP/gh/comments.json")|$(cat "$TMP/gh/writes.log")" "dry run: no comment and no stamp"
assert_eq "0" "$(compgen -G "$TMP/worktrees/.review/*" | wc -l | tr -d ' ')" "dry run: no reviewer worktree"
assert_eq "7" "$(jq_out "r.review.filter(x=>x.action==='would-launch').length")" "dry run: the report says what would run, one per PR"
assert_contains "$(jq_out "r.review.find(x=>x.pr===200).detail")" "stub-a" "dry run: the report names the reviewer"
assert_contains "$TEXT" "**Review**" "report: a Review section"
assert_contains "$TEXT" "· awaiting-reviewer 7 · reviewing 0" "report: counts carry awaiting-reviewer and reviewing"

# --- launch: one reviewer per PR, in a fresh worktree at its head -----------------
cycle
assert_eq "7" "$(st 'v.inFlight.length')" "launch: seven reviews recorded in flight in state.review"
assert_eq "{\"pr\":200,\"reviewer\":\"stub-a\",\"headSha\":\"$H200\",\"issue\":10}" "$(st 'v.inFlight.filter(x=>x.pr===200).map(x=>({pr:x.pr,reviewer:x.reviewer,headSha:x.headSha,issue:x.issue}))[0]')" "launch: the record is { pr, reviewer, headSha, issue, ... }"
assert_eq "[true,true]" "$(st '[Number.isInteger(v.inFlight[0].pid),Boolean(v.inFlight[0].startedAt)]')" "launch: the record has pid and startedAt"
assert_eq "0" "$(jq_out 'r.streak')" "streak: reviews in flight are live work (noMovementLimit 1, nothing else live)"
assert_eq "null" "$(st 's.latched')" "streak: no latch while reviews run"
wait_for_count "$RLOG" "*.1.env" 7
ENV200=$(cat "$RLOG/200.1.env")
assert_contains "$ENV200" "head=$H200" "launch: the worktree is at the PR head"
WT200=$(sed -n 2p "$RLOG/200.1.argv")
assert_contains "$ENV200" "cwd=$WT200" "launch: the reviewer runs in the worktree, {worktree} replaced"
assert_contains "$WT200" "$TMP/worktrees/.review/" "launch: a reviewer worktree of its own"
assert_ne "$TMP/worktrees/api-t1-1" "$WT200" "launch: not the worker's worktree"
assert_contains "$(sed -n 3p "$RLOG/200.1.argv")" "$TMP/state/review/" "launch: {out} is outside the worktree"
P200=$(cat "$RLOG/200.1.prompt")
assert_contains "$P200" "Goal of T1.1: make the widget count." "prompt: the package issue body"
assert_contains "$P200" "+work for T1.1" "prompt: the diff against the base"
assert_contains "$P200" "test: true" "prompt: the manifest's checks"
assert_contains "$P200" "presumed wrong until shown otherwise" "prompt: the brief"
assert_contains "$P200" "change no file" "prompt: the reviewer changes no file"
assert_contains "$P200" '"verdict"' "prompt: the verdict format"
assert_contains "$(sed -n 1p "$RLOG/200.1.argv")" "$TMP/state/review/" "launch: {prompt} replaced by the prompt file path"

# --- one in flight per PR; a pass stamps; a fail comments and re-dispatches --------
wait_for_count "$TMP/state/review" "*/exit" 5
cycle
assert_eq "1" "$(argv_count 205)" "in flight: a running review is not launched again"
assert_eq "1" "$(argv_count 200)" "in flight: one reviewer per PR"
STAMP200=$(comments_on 200)
assert_contains "$(first_lines 200)" "REVIEWED: stub-a @ $H200" "pass: REVIEWED: <name> @ <head> on the PR"
assert_contains "$STAMP200" "checked the content" "pass: the findings it checked follow the stamp"
assert_contains "$(cat "$TMP/gh/writes.log")" "comment acme/api 200" "pass: written to the target repo"
C201=$(comments_on 201)
assert_not_contains "$C201" "REVIEWED:" "fail: no stamp"
assert_contains "$C201" "the guard is inverted" "fail: the findings are commented"
assert_contains "$C201" "src/y.txt:9" "fail: each finding with file and line"
assert_eq "\"$H201\"" "$(st 'v.failed["201"]["stub-a"].headSha')" "fail: the head is recorded in state.review.failed"
assert_eq "default|2" "$(jq_out "r.launched.filter(l=>l.issue===11).map(l=>l.tier+'|'+l.attempt).join()")" "fail: the worker is re-dispatched at the same tier"
assert_eq "2|review-failed: the guard is inverted|default" "$(node -e "const d=require('$TMP/state/state.json').dispatches['T1.2']; console.log(d.length+'|'+d[1].reason+'|'+d[1].tier)")" "fail: the re-dispatch is a dispatch, counted toward maxEscalations, reason review-failed: <first claim>"
for n in 202 203 204; do assert_not_contains "$(comments_on $n)" "REVIEWED:" "no stamp on #$n"; done
assert_contains "$(alarm_detail review-invalid)" "#202" "invalid JSON: alarm review-invalid"
assert_contains "$(alarm_detail review-wrote)" "#203" "a reviewer that changed the worktree: review-wrote"
assert_contains "$(alarm_detail review-wrote)" "#204" "a reviewer that moved HEAD: review-wrote"
assert_contains "$(alarm_detail review-wrote)" "stub-a" "review-wrote names the reviewer"
assert_eq "alarm" "$(jq_out r.outcome)" "a review fault makes the cycle an alarm"

# --- timeout ------------------------------------------------------------------
node -e "const f='$TMP/state/state.json',fs=require('fs');const s=JSON.parse(fs.readFileSync(f,'utf8'));s.review['acme/api'].inFlight.find(x=>x.pr===206).startedAt=new Date(Date.now()-3600e3).toISOString();fs.writeFileSync(f,JSON.stringify(s,null,2))"
PID206=$(st 'v.inFlight.find(x=>x.pr===206).pid')
# --- a head that moves while the review runs ---------------------------------------
git -C "$TMP/worktrees/api-t1-6" -c user.name=stub -c user.email=stub@example.invalid commit -q --allow-empty -m "worker push" && git -C "$TMP/worktrees/api-t1-6" push -q origin HEAD
set_head 205 "$(git -C "$TMP/worktrees/api-t1-6" rev-parse HEAD)"
cycle
assert_contains "$(alarm_detail review-timeout)" "#206" "timeout: alarm review-timeout"
assert_not_contains "$(comments_on 206)" "REVIEWED:" "timeout: no stamp"
sleep 1
kill -0 "$PID206" 2>/dev/null && _fail "timeout: the reviewer is stopped" || _pass "timeout: the reviewer is stopped"
touch "$TMP/gate"
wait_for_count "$TMP/state/review" "*-205-*/exit" 1
cycle
assert_contains "$(alarm_detail review-stale)" "#205" "moved head: alarm review-stale"
assert_not_contains "$(comments_on 205)" "REVIEWED:" "moved head: no stamp"
assert_eq "1" "$(argv_count 201)" "fail: the reviewer is not run again at the head it failed"
assert_contains " $(labels_of 10) " " cell:awaiting-review " "sync: the REVIEWED stamp meets the policy: cell:awaiting-review"
assert_not_contains "$(labels_of 10)" "cell:awaiting-reviewer" "sync: no longer awaiting a reviewer"
assert_eq "0" "$(st 'v.inFlight.length')" "every run reaped"
assert_eq "0" "$(compgen -G "$TMP/worktrees/.review/*" | wc -l | tr -d ' ')" "reviewer worktrees are removed after the run"

finish
