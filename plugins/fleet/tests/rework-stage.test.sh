#!/usr/bin/env bash
# The rework stage (src/rework.js): a person who has read the reviews on a
# package PR asks for rework by commenting `REWORK: <who> @ <full head sha>`.
# The next cycle sends the worker that opened the PR back at the same tier,
# through the review-failed path, so the re-dispatch is recorded in the
# dispatch history and counts toward maxEscalations. A marker is acted on once
# per head; a marker at an old head is ignored; a PR with no session on this
# machine is an alarm, raised once. Driven end to end through `fleet cycle`
# against a real git remote, the plugin scripts, and the gh and claude stubs.
set -uo pipefail
cd "$(dirname "$0")"
. ./lib.sh

FLEET="$(cd .. && pwd -P)/bin/fleet.js"
SRC="$(cd .. && pwd -P)/src"
PLUGIN="$(cd ../../agentic-work-packages && pwd -P)"
HERE=$(pwd -P)
assert_file "$FLEET" "fleet.js exists"
assert_file "$SRC/rework.js" "rework.js exists"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
TMP=$(cd "$TMP" && pwd -P)

# --- the marker ------------------------------------------------------------------
SHA_A=$(printf 'a%.0s' $(seq 40)); SHA_B=$(printf 'b%.0s' $(seq 40))
cur() { node -e "const {currentRework}=require('$SRC/rework.js'); console.log(JSON.stringify(currentRework({headSha:process.argv[1],comments:JSON.parse(process.argv[2])})))" "$1" "$2"; }
assert_eq "{\"who\":\"tt-jphan, KhinDLuu\",\"sha\":\"$SHA_A\"}" "$(cur "$SHA_A" "[\"REWORK: tt-jphan, KhinDLuu @ $SHA_A\\n\\nsee the reviews\"]")" "marker: who and sha from the first line"
assert_eq "null" "$(cur "$SHA_B" "[\"REWORK: jack @ $SHA_A\"]")" "marker: a marker at another head is not current"
assert_eq "null" "$(cur "$SHA_A" "[\"please REWORK: jack @ $SHA_A\"]")" "marker: only at the start of a line"
assert_eq "null" "$(cur "$SHA_A" "[\"REWORK: jack @ ${SHA_A:0:7}\"]")" "marker: a short sha is not a marker"
assert_eq "null" "$(cur "" "[\"REWORK: jack @ $SHA_A\"]")" "marker: no head, no marker"

# --- a real remote and clone, no review policy -------------------------------------
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

# Three packages, T1.1..T1.3 (#10..#12), whose PRs are #200..#202.
scope_body() { # branch id
  printf '**Part of** #1 · **Phase 0 · x** · **Repo:** `acme/api`\n\n## Goal\nGoal of %s.\n\n### SCOPE.json\n```json\n{"feature":"f","branch":"%s","allowedPaths":["src/**"],"forbiddenPaths":[],"dependsOn":[],"execution":{"model":"default","pattern":"solo"}}\n```\n' "$2" "$1"
}
node - "$TMP/gh" $(for k in 1 2 3; do printf '%s ' "$(scope_body "feat/t1-$k" "T1.$k" | base64 -w0)"; done) <<'JS'
const fs = require('fs'); const [dir, ...bodies] = process.argv.slice(2);
const q = (k, body) => ({ number: 9 + k, title: `T1.${k} Package ${k}`, body: Buffer.from(body, 'base64').toString(), state: 'OPEN', labels: ['agent-ready', 'cell:queued', 'worker:a'] });
fs.writeFileSync(`${dir}/issues.json`, JSON.stringify([
  { number: 1, title: 'Epic: program T', body: '', state: 'OPEN', labels: ['epic'] },
  ...bodies.map((b, i) => q(i + 1, b)),
], null, 2));
fs.writeFileSync(`${dir}/prs.json`, '[]'); fs.writeFileSync(`${dir}/labels.json`, '{}');
fs.writeFileSync(`${dir}/comments.json`, '{}'); fs.writeFileSync(`${dir}/writes.log`, '');
JS

cat > "$TMP/fleet.config.json" <<JSON
{
  "repo": "acme/host", "epic": 1,
  "targets": [{ "repo": "acme/api", "localPath": "$TMP/api", "defaultBranch": "main" }],
  "workers": { "a": { "mode": "local" } },
  "wipCap": 8, "worktreesDir": "$TMP/worktrees", "stateDir": "$TMP/state",
  "pluginRoot": "$PLUGIN", "maxEscalations": 1, "noMovementLimit": 5, "sessionTimeoutMinutes": 5
}
JSON
fleet() { node "$FLEET" "$@" --config "$TMP/fleet.config.json"; }
cycle() { OUT=$(fleet cycle --apply --json 2>"$TMP/cycle.err"); EXIT=$?; }
wait_exit() { local f="$TMP/state/logs/$1.exit" i=0; until [ -f "$f" ] || [ $i -ge 60 ]; do sleep 0.5; i=$((i + 1)); done; [ -f "$f" ]; }
pr_field() { node -e "const p=require('$TMP/gh/prs.json').find(x=>x.number===$1); console.log(p.$2)"; }
add_comment() { node -e "const f='$TMP/gh/comments.json',fs=require('fs');const a=JSON.parse(fs.readFileSync(f,'utf8'));const k='acme/api#$1';a[k]=[...(a[k]||[]),{id:Date.now(),body:process.argv[1],created_at:new Date().toISOString()}];fs.writeFileSync(f,JSON.stringify(a,null,2))" "$2"; }
jq_out() { printf '%s' "$OUT" | node -e "const r=JSON.parse(require('fs').readFileSync(0,'utf8')); console.log($1)"; }
alarm_codes() { jq_out "r.alarms.map(a=>a.code).join(' ')"; }
alarm_detail() { jq_out "r.alarms.filter(a=>a.code==='$1').map(a=>a.detail).join(' | ')"; }
dispatches() { node -e "const d=require('$TMP/state/state.json').dispatches['$1']||[]; console.log(JSON.stringify(d.map(x=>({n:x.n,tier:x.tier,reason:x.reason}))))"; }
launched_for() { jq_out "r.launched.filter(l=>l.issue===$1).map(l=>l.tier+'|'+l.attempt).join()"; }
argv_count() { compgen -G "$TMP/claude-log/$1.*.argv" | wc -l | tr -d ' '; }

# --- setup: three PRs, every worker session closed --------------------------------
for k in 1 2 3; do export "CLAUDE_STUB_MODE_T1_$k=pr"; done
for k in 1 2 3; do fleet launch $((9 + k)) --apply >/dev/null 2>&1; wait_exit "$((9 + k))-1"; done
assert_eq "[READY]: T1.1 done|[READY]: T1.3 done" "$(pr_field 200 title)|$(pr_field 202 title)" "setup: PRs #200 (T1.1) .. #202 (T1.3)"
for k in 1 2 3; do export "CLAUDE_STUB_MODE_T1_$k=silent"; done
cycle
assert_eq "0" "$(jq_out 'r.launched.length')" "setup: a cycle with no marker launches nothing"
H200=$(pr_field 200 headRefOid); H201=$(pr_field 201 headRefOid); H202=$(pr_field 202 headRefOid)

# --- markers: one current, one at an old head --------------------------------------
add_comment 200 "REWORK: tt-jphan, KhinDLuu @ $H200

Jack: B2A01 17 and 46 are cancellations. Khin: the first run floods."
add_comment 201 "REWORK: jack @ $SHA_A"

# --- dry run: no launch, no state ------------------------------------------------
S0=$(cat "$TMP/state/state.json")
OUT=$(fleet cycle --json 2>/dev/null)
TEXT=$(fleet cycle 2>/dev/null)
assert_eq "would-rework" "$(jq_out "r.review.filter(x=>x.pr===200).map(x=>x.action).join()")" "dry run: the report says it would send T1.1 back"
assert_contains "$(jq_out "r.review.find(x=>x.pr===200).detail")" "tt-jphan, KhinDLuu" "dry run: the report names who asked"
assert_contains "$TEXT" "acme/api#200: would-rework" "dry run: the text report carries it in the Review section"
assert_eq "$S0" "$(cat "$TMP/state/state.json")" "dry run: the state file is unchanged"
assert_eq "1" "$(argv_count T1.1)" "dry run: no worker is launched"

# --- apply: the worker is sent back once, through review-failed ---------------------
cycle
assert_eq "default|2" "$(launched_for 10)" "rework: T1.1 is re-dispatched at the same tier, attempt 2"
REASON=$(node -e "const d=require('$TMP/state/state.json').dispatches['T1.1']; console.log(d[1].reason)")
assert_contains "$REASON" "review-failed: REWORK by tt-jphan, KhinDLuu at ${H200:0:7}" "rework: the dispatch reason is review-failed and names who asked and the head"
assert_contains "$REASON" "PR #200" "rework: the reason points the worker at the PR"
assert_eq "2" "$(node -e "console.log(require('$TMP/state/state.json').dispatches['T1.1'].length)")" "rework: the re-dispatch is recorded in the dispatch history"
assert_eq "\"$H200\"" "$(node -e "console.log(JSON.stringify(require('$TMP/state/state.json').rework['acme/api']['200']))")" "rework: the head acted on is recorded in state.rework"
assert_contains "$(jq_out "r.movement.map(m=>m.package+':'+m.artifact.type).join(' ')")" "T1.1:dispatch" "rework: the dispatch is movement"
assert_eq "rework" "$(jq_out "r.review.filter(x=>x.pr===200).map(x=>x.action).join()")" "rework: the Review section records it"
wait_exit "10-2"
assert_contains "$(cat "$TMP/claude-log/T1.1.2.argv")" "The previous attempt ended with: review-failed: REWORK by tt-jphan, KhinDLuu" "rework: the worker prompt carries the reason"
assert_eq "" "$(launched_for 11)" "old head: a marker at another sha sends nobody back"
assert_eq "" "$(jq_out "r.review.filter(x=>x.pr===201).map(x=>x.action).join()")" "old head: nothing is noted for it"
assert_not_contains "$(alarm_codes)" "review-" "rework: no review alarm"

# --- the same marker is acted on once -----------------------------------------------
cycle
assert_eq "" "$(launched_for 10)" "once: the next cycle does not send T1.1 back again"
assert_eq "2" "$(node -e "console.log(require('$TMP/state/state.json').dispatches['T1.1'].length)")" "once: the dispatch history is unchanged"

# --- a new head takes a new marker, and maxEscalations still holds ------------------
export CLAUDE_STUB_MODE_T1_2=pr-update
add_comment 201 "REWORK: khin @ $H201"
cycle
assert_eq "default|2" "$(launched_for 11)" "T1.2: a current marker sends it back"
wait_exit "11-2"
H201B=$(pr_field 201 headRefOid)
assert_ne "$H201" "$H201B" "T1.2: the rework pushed a new head"
add_comment 201 "REWORK: khin @ $H201B"
cycle
assert_eq "" "$(launched_for 11)" "cap: a second rework past maxEscalations 1 is not launched"
assert_contains "$(alarm_detail escalation-cap)" "T1.2" "cap: alarm escalation-cap names the package"
assert_contains "$(alarm_detail escalation-cap)" "REWORK by khin" "cap: the alarm carries the rework reason"

# --- no session on this machine: an alarm, raised once -----------------------------
node -e "const f='$TMP/state/state.json',fs=require('fs');const s=JSON.parse(fs.readFileSync(f,'utf8'));delete s.sessions['12'];fs.writeFileSync(f,JSON.stringify(s,null,2))"
add_comment 202 "REWORK: jack @ $H202"
cycle
assert_contains "$(alarm_detail review-redispatch-failed)" "T1.3" "no session: alarm review-redispatch-failed names the package"
assert_contains "$(alarm_detail review-redispatch-failed)" "#202" "no session: the alarm names the PR"
assert_eq "" "$(launched_for 12)" "no session: nobody is launched"
cycle
assert_not_contains "$(alarm_codes)" "review-redispatch-failed" "no session: the alarm is not raised again at the same head"

finish
