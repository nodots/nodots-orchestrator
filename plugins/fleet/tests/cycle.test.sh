#!/usr/bin/env bash
# End-to-end fixture test for `fleet cycle` against a real git remote, the real
# plugin scripts, a stateful gh stub and a scripted claude stub.
#
# What is proved: a dry run writes nothing; an applied cycle promotes, assigns,
# creates worktrees, commits and pushes the scope, launches with the right
# argv and env, and posts one report; the next cycle reaps a PR as movement,
# parks a BLOCKER, escalates a silent run one tier up; the escalation cap
# holds; idle cycles write no labels and latch after the limit; resume clears
# it; a truncated sync launches nothing; a live lock refuses a second cycle.
set -uo pipefail
cd "$(dirname "$0")"
. ./lib.sh

HERE=$(pwd -P)
FLEET="$(cd .. && pwd -P)/bin/fleet.js"
PLUGIN="$(cd ../../agentic-work-packages && pwd -P)"
assert_file "$FLEET" "fleet.js exists"
assert_file "$PLUGIN/skills/agentic-work-packages/assets/scripts/sync-cells.sh" "the agentic-work-packages scripts are beside fleet"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
TMP=$(cd "$TMP" && pwd -P)

# --- a real remote and clone --------------------------------------------------
git init -q --bare -b main "$TMP/remote.git"
git clone -q "$TMP/remote.git" "$TMP/clone" 2>/dev/null
git -C "$TMP/clone" checkout -q -b main 2>/dev/null || true
git -C "$TMP/clone" config user.email f@example.invalid; git -C "$TMP/clone" config user.name fixture
printf '# api\n' > "$TMP/clone/README.md"
git -C "$TMP/clone" add -A && git -C "$TMP/clone" commit -qm init && git -C "$TMP/clone" push -q -u origin main
fixture_standards "$TMP/clone" && git -C "$TMP/clone" push -q origin main
git -C "$TMP/clone" checkout -q -b feat/t1-0-base && printf 'base\n' > "$TMP/clone/base.txt" && git -C "$TMP/clone" add -A && git -C "$TMP/clone" commit -qm "T1.0: base" && git -C "$TMP/clone" push -q origin feat/t1-0-base && git -C "$TMP/clone" checkout -q main
BASE_SHA=$(git -C "$TMP/clone" rev-parse feat/t1-0-base)

# --- stubs -------------------------------------------------------------------
STUB="$TMP/stub"; mkdir -p "$STUB" "$TMP/gh" "$TMP/claude-log"
cp "$HERE/stubs/gh.js" "$STUB/gh.js"
printf '#!/usr/bin/env bash\nexec node "%s/gh.js" "$@"\n' "$STUB" > "$STUB/gh"; chmod +x "$STUB/gh"
cp "$HERE/stubs/claude.sh" "$STUB/claude"; chmod +x "$STUB/claude"
export GH_STUB_DIR="$TMP/gh" GH_STUB_REMOTE="$TMP/remote.git" CLAUDE_STUB_LOG="$TMP/claude-log" CLAUDE_STUB_TARGET="acme/api"
export GH_BIN="$STUB/gh" CLAUDE_BIN="$STUB/claude"
# Trust lives in ~/.claude.json keyed by the main clone; the fixture uses its own file.
export CLAUDE_CONFIG_FILE="$TMP/claude.json"
node -e "require('fs').writeFileSync('$TMP/claude.json', JSON.stringify({projects:{['$TMP/clone']:{hasTrustDialogAccepted:true}}}))"
unset CLAUDECODE; export CLAUDECODE=1    # the launcher must strip this

scope_body() { # branch deps-json
  printf '**Part of** #1 · **Phase 1 · x** · **Repo:** `acme/api`\n\n## Goal\nx\n\n### SCOPE.json\n```json\n{"feature":"f","branch":"%s","allowedPaths":["src/**"],"forbiddenPaths":["contracts/**"],"dependsOn":%s,"execution":{"model":"default","pattern":"solo"}}\n```\n' "$1" "$2"
}
OTHER_EPIC_BODY=$(scope_body feat/u1-1-other '[]' | sed 's/\*\*Part of\*\* #1 /**Part of** #2 /')
node - "$TMP/gh" "$(scope_body feat/t1-1-first '[]')" "$(scope_body feat/t1-2-second '["feat/t1-0-base"]')" "$(scope_body feat/t1-3-silent '[]')" "$(scope_body feat/t1-4-blocker '[]')" "$(scope_body feat/t1-5-external '[]')" "$(scope_body feat/t1-0-base '[]')" "$BASE_SHA" "$OTHER_EPIC_BODY" <<'JS'
const fs = require('fs'); const [dir, b11, b12, b13, b14, b15, b10, sha, bOther] = process.argv.slice(2);
fs.writeFileSync(`${dir}/issues.json`, JSON.stringify([
  { number: 1, title: 'Epic: program T', body: '', state: 'OPEN', labels: ['epic'] },
  { number: 9, title: 'T1.0 Base', body: b10, state: 'CLOSED', labels: ['agent-ready', 'cell:active'] },
  { number: 10, title: 'T1.1 First thing', body: b11, state: 'OPEN', labels: ['agent-ready', 'cell:queued', 'worker:a'] },
  { number: 11, title: 'T1.2 Second thing', body: b12, state: 'OPEN', labels: ['agent-ready'] },
  { number: 12, title: 'T1.3 Silent one', body: b13, state: 'OPEN', labels: ['agent-ready', 'cell:queued', 'worker:a'] },
  { number: 13, title: 'T1.4 Blocked one', body: b14, state: 'OPEN', labels: ['agent-ready', 'cell:queued', 'worker:a'] },
  { number: 14, title: 'T1.5 External one', body: b15, state: 'OPEN', labels: ['agent-ready', 'cell:queued', 'worker:x'] },
  // Another program in the same host repo: ready, no dependencies, so only the
  // epic filter keeps the cycle from promoting and launching it.
  { number: 20, title: 'U1.1 Other program', body: bOther, state: 'OPEN', labels: ['agent-ready'] },
  // A package of that program already in the lifecycle: only sync --epic keeps
  // it out of the sync state.
  { number: 21, title: 'U1.2 Other program, active', body: bOther.replace('feat/u1-1-other', 'feat/u1-2-other'), state: 'OPEN', labels: ['agent-ready', 'cell:active'] },
], null, 2));
fs.writeFileSync(`${dir}/prs.json`, JSON.stringify([
  { number: 100, title: '[READY]: T1.0 base', body: 'Closes #9', state: 'MERGED', headRefName: 'feat/t1-0-base', headRefOid: sha, isDraft: false, url: 'u', repo: 'acme/api' },
], null, 2));
fs.writeFileSync(`${dir}/labels.json`, '{}'); fs.writeFileSync(`${dir}/comments.json`, '{}'); fs.writeFileSync(`${dir}/writes.log`, '');
JS

cat > "$TMP/fleet.config.json" <<JSON
{
  "repo": "acme/host", "epic": 1,
  "targets": [{ "repo": "acme/api", "localPath": "$TMP/clone", "defaultBranch": "main" }],
  "workers": { "a": { "mode": "local" }, "x": { "mode": "external" } },
  "wipCap": 4, "worktreesDir": "$TMP/worktrees", "stateDir": "$TMP/state",
  "pluginRoot": "$PLUGIN", "maxEscalations": 1, "noMovementLimit": 3, "sessionTimeoutMinutes": 5,
  "models": { "cheapest": "haiku", "default": null, "strongest": "opus" }
}
JSON
fleet() { node "$FLEET" "$@" --config "$TMP/fleet.config.json"; }
edits() { grep -c '^edit ' "$TMP/gh/writes.log" || true; }
wait_exit() { local f="$TMP/state/logs/$1.exit" i=0; until [ -f "$f" ] || [ $i -ge 60 ]; do sleep 0.5; i=$((i + 1)); done; [ -f "$f" ]; }
markers() { grep -o 'fleet-cycle:[A-Za-z0-9-]*' "$TMP/gh/comments.json" | sort -u | wc -l | tr -d ' '; }

export CLAUDE_STUB_MODE_T1_1=pr CLAUDE_STUB_MODE_T1_3=silent CLAUDE_STUB_MODE_T1_4=blocker

# --- A. dry run writes nothing ----------------------------------------------
OUT=$(fleet cycle --json 2>"$TMP/errA"); EXIT=$?
assert_eq 0 "$EXIT" "dry run exits 0"
assert_eq "0" "$(edits)" "dry run writes no labels"
assert_eq "0" "$(markers)" "dry run posts no report"
[ -d "$TMP/worktrees" ] && _fail "dry run creates no worktree" "worktrees dir exists" || _pass "dry run creates no worktree"
assert_contains "$OUT" '"dryRun": true' "dry run says so in JSON"
assert_contains "$OUT" '"id": "T1.2"' "dry run computes the promotion of T1.2 (its dependency merged)"
assert_contains "$(cat "$TMP/errA")" "fleet cycle" "the one-line summary goes to stderr"
assert_not_contains "$OUT" '"id": "U1.1"' "a ready package of another epic is not promoted"
synced_numbers=$(node -e 'process.stdout.write(require(process.argv[1]).issues.map(i=>i.number).join(","))' "$TMP/state/sync-state.json" 2>/dev/null || echo "no sync-state.json")
assert_not_contains ",$synced_numbers," ",21," "sync runs with --epic: the other epic's package is not in the sync state"
assert_contains ",$synced_numbers," ",10," "the epic's own packages are in the sync state"

# --- A2. an untrusted clone refuses to launch, before any worktree is made ----
OUT=$(CLAUDE_CONFIG_FILE="$TMP/untrusted.json" fleet cycle --apply --json 2>/dev/null); EXIT=$?
assert_contains "$OUT" '"code": "launch-trust"' "an untrusted workspace is refused at launch with a trust alarm"
assert_contains "$OUT" 'hasTrustDialogAccepted' "the alarm says how to trust the workspace"
[ -d "$TMP/worktrees" ] && _fail "no worktree is created for a refused launch" "worktrees dir exists" || _pass "no worktree is created for a refused launch"
assert_contains "$(grep '^edit 11' "$TMP/gh/writes.log")" "+cell:queued" "promotion still happened before the refusal (labels are tracker state, not launch state)"
rm -rf "$TMP/state"
printf '{}' > "$TMP/gh/comments.json"   # the refusal posted its own alarm report; B counts from zero

# --- A3. crash recovery: a launch that dies after its push, then after its record
# FLEET_CRASH_AT is honored only with FLEET_TEST_HOOKS=1. The package is T1.1
# alone (FLEET_ONLY_ISSUE), so the rest of the fixture is untouched.
OUT=$(FLEET_TEST_HOOKS=1 FLEET_CRASH_AT=after-push FLEET_ONLY_ISSUE=10 fleet cycle --apply --json 2>"$TMP/crash1.err"); EXIT=$?
assert_ne 0 "$EXIT" "a crash after the push exits non-zero"
assert_contains "$(cat "$TMP/crash1.err")" "FLEET_CRASH_AT=after-push" "the crash point is named"
[ -d "$TMP/worktrees/api-t1-1" ] && _pass "the worktree was created before the crash" || _fail "the worktree was created before the crash" "missing"
assert_contains "$(git --git-dir "$TMP/remote.git" for-each-ref --format='%(refname:short)' refs/heads)" "feat/t1-1-first" "the scope branch was pushed before the crash"
[ -f "$TMP/state/state.json" ] && assert_not_contains "$(cat "$TMP/state/state.json")" '"issue": 10' "no session record exists for the crashed launch" || _pass "no session record exists for the crashed launch"
[ -f "$TMP/state/cycle.lock" ] && _pass "a hard crash leaves the lock behind (the next cycle must take it over)" || _fail "a hard crash leaves the lock behind (the next cycle must take it over)" "no cycle.lock"

OUT=$(FLEET_TEST_HOOKS=1 FLEET_CRASH_AT=after-persist FLEET_ONLY_ISSUE=10 fleet cycle --apply --json 2>"$TMP/crash2.err"); EXIT=$?
assert_contains "$(cat "$TMP/crash2.err")" "stale lock" "the next cycle takes over the dead cycle's lock"
assert_ne 0 "$EXIT" "a crash after the record exits non-zero"
assert_contains "$(grep '^edit 10' "$TMP/gh/writes.log" | tail -1)" "+cell:active" "sync relabeled the orphan cell:active before adoption, and adoption still happened"
assert_contains "$(cat "$TMP/state/state.json")" '"status": "launching"' "the record was written as launching before the crash"
N=$(git --git-dir "$TMP/remote.git" rev-list --count main..feat/t1-1-first)
assert_eq "1" "$N" "the orphaned worktree was adopted: still exactly one scope commit on the branch, no second push"

OUT=$(FLEET_ONLY_ISSUE=10 fleet cycle --apply --json 2>/dev/null); EXIT=$?
assert_eq 0 "$EXIT" "the recovery cycle exits 0"
assert_contains "$OUT" '"outcome": "relaunch"' "a launching record with no process is classified relaunch, not escalate"
assert_contains "$OUT" '"adopted": true' "the relaunch adopts the existing worktree"
# The stub worker may already have pushed its own commit; count only scope commits.
assert_eq "1" "$(git --git-dir "$TMP/remote.git" log --format=%s main..feat/t1-1-first | grep -c 'scope')" "recovery pushes no second scope commit and no re-cut"
assert_eq "1" "$(node -e "const s=require('$TMP/state/state.json'); console.log(Object.keys(s.sessions).length)")" "exactly one session record after recovery"
assert_eq "1" "$(node -e "const s=require('$TMP/state/state.json'); console.log((s.dispatches['T1.1']||[]).length)")" "a relaunch after a crash is not a new dispatch"
assert_contains "$(cat "$TMP/state/state.json")" '"status": "running"' "the recovered session is running"
printf '{}' > "$TMP/gh/comments.json"   # the crash cycles posted reports; B counts from zero
unset FLEET_ONLY_ISSUE

# --- B. first applied cycle: promote, assign, launch, report -----------------
OUT=$(fleet cycle --apply --json 2>/dev/null); EXIT=$?
assert_eq 0 "$EXIT" "applied cycle exits 0"
assert_contains "$OUT" '"outcome": "movement"' "launching is movement"
assert_contains "$(grep '^edit 11' "$TMP/gh/writes.log")" "+cell:queued" "T1.2 was promoted in the tracker"
assert_eq "1" "$(markers)" "one report posted to the epic"
assert_contains "$(grep '^edit 10' "$TMP/gh/writes.log" | tail -1)" "+cell:active" "sync derived cell:active for the package A3 pushed"
for s in t1-1 t1-3 t1-4; do
  [ -d "$TMP/worktrees/api-$s" ] && _pass "worktree api-$s created" || _fail "worktree api-$s created" "missing"
done
[ -d "$TMP/worktrees/api-t1-5" ] && _fail "external worker's package is not launched here" "worktree exists" || _pass "external worker's package is not launched here"
[ -d "$TMP/worktrees/api-t1-2" ] && _fail "T1.2 is held by the WIP cap this cycle (4 in flight)" "worktree exists" || _pass "T1.2 is held by the WIP cap this cycle (4 in flight)"
BR=$(git --git-dir "$TMP/remote.git" for-each-ref --format='%(refname:short)' refs/heads | sort | tr '\n' ' ')
assert_contains "$BR" "feat/t1-1-first" "the scope branch was pushed (the claim)"
# The stub worker may already have pushed its own commit on top; the scope
# commit is the first one after main either way.
MSG=$(git --git-dir "$TMP/remote.git" log --format=%s main..feat/t1-1-first | tail -1)
assert_eq "T1.1: scope" "$MSG" "the first commit on the branch is the scope commit"
git --git-dir "$TMP/remote.git" cat-file -e 'feat/t1-1-first:.agentic/cells/feat/t1-1-first/SCOPE.json' && _pass "SCOPE.json is committed in the cell directory" || _fail "SCOPE.json is committed in the cell directory" "missing"
# T1.1's worker was started by the recovery cycle in A3; the stub writes .env
# after .argv, so wait for both.
wait_for_file "$TMP/claude-log/T1.1.1.argv"; wait_for_file "$TMP/claude-log/T1.1.1.env"
ARGV=$(cat "$TMP/claude-log/T1.1.1.argv"); ENVF=$(cat "$TMP/claude-log/T1.1.1.env")
assert_contains "$ARGV" "-p" "worker is launched with -p"
assert_contains "$ARGV" "--output-format" "worker is launched with --output-format"
assert_contains "$ARGV" "acceptEdits" "default permission mode is acceptEdits"
assert_contains "$ARGV" "--permission-prompts" "permission prompts are disabled for unattended runs"
assert_contains "$ARGV" "--max-budget-usd" "a budget cap is passed"
assert_not_contains "$ARGV" "--model" "the default tier passes no --model"
assert_contains "$ARGV" "worker-contract.md" "the prompt points at the worker contract"
assert_contains "$ARGV" "[READY]: T1.1" "the prompt names the PR title convention"
assert_not_contains "$ARGV" "--bare" "workers never run --bare (hooks must load)"
assert_contains "$ENVF" "cwd=$TMP/worktrees/api-t1-1" "worker cwd is its worktree"
assert_contains "$ENVF" "CLAUDECODE=<unset>" "CLAUDECODE is stripped from the worker env"
assert_contains "$ENVF" "FLEET_PACKAGE=T1.1" "FLEET_PACKAGE is set"
assert_contains "$ENVF" "FLEET_WORKER_ID=a" "FLEET_WORKER_ID is set"
STATE=$(cat "$TMP/state/state.json")
assert_contains "$STATE" '"status": "running"' "session records are persisted as running"
assert_contains "$STATE" '"launchHeadSha"' "the head sha at launch is recorded"

# --- C. wait for the three stub workers --------------------------------------
wait_exit 10-1 && wait_exit 12-1 && wait_exit 13-1 && _pass "all three workers exited" || _fail "all three workers exited" "exit files missing"

# --- D. second cycle: reap PR, park blocker, escalate silent -----------------
OUT=$(fleet cycle --apply --json 2>/dev/null); EXIT=$?
assert_eq 0 "$EXIT" "second cycle exits 0"
assert_contains "$OUT" '"outcome": "movement"' "a reaped PR is movement"
# T1.1's stub may have finished before B or before D; the PR is named in whichever cycle reaped it.
assert_contains "$(cat "$TMP"/state/cycles/*.json)" '"type": "pr"' "the PR artifact is named in the cycle that reaped it"
assert_eq "pr" "$(node -e "console.log(require('$TMP/state/state.json').sessions[10].outcome)")" "T1.1's session outcome is pr"
assert_contains "$OUT" '"outcome": "parked"' "the BLOCKER.md package is parked"
assert_contains "$OUT" 'kind=human-decision' "the Kind is surfaced"
assert_contains "$OUT" '"reason": "silent"' "the silent run is escalated with reason silent"
assert_contains "$OUT" '"to": "strongest"' "escalation goes one tier up"
wait_exit 12-2 && _pass "the escalated relaunch ran" || _fail "the escalated relaunch ran" "no exit file 12-2"
ARGV2=$(cat "$TMP/claude-log/T1.3.2.argv")
assert_contains "$ARGV2" "--model" "the escalated attempt passes --model"
assert_contains "$ARGV2" "opus" "the escalated attempt uses the strongest alias"
assert_contains "$ARGV2" "attempt 2" "the prompt says it is attempt 2"
# Read at once: the cycle chose not to launch T1.1 or T1.4, so no stub was
# spawned for them. A wrong relaunch would have been spawned with T1.3's
# attempt 2, which has already exited (wait_exit 12-2 above).
assert_not_contains "$(ls "$TMP/claude-log")" "T1.1.2" "the package with a PR is not relaunched"
assert_not_contains "$(ls "$TMP/claude-log")" "T1.4.2" "a parked package is not relaunched"
assert_contains "$(grep '^edit 12' "$TMP/gh/writes.log" | tail -1)" "+cell:active" "sync derived cell:active for the branch-only package"
assert_eq "2" "$(markers)" "a second, distinct report was posted"

# --- E. third cycle: escalation cap holds ------------------------------------
OUT=$(fleet cycle --apply --json 2>/dev/null); EXIT=$?
assert_contains "$OUT" '"code": "escalation-cap"' "after maxEscalations the package is held with an alarm"
# Read at once: escalation-cap holds the package before the spawn, so no
# detached stub exists to write here later.
assert_not_contains "$(ls "$TMP/claude-log")" "T1.3.3" "no third attempt is launched"
assert_contains "$OUT" '"outcome": "alarm"' "an escalation cap with nothing else moving is an alarm"
assert_contains "$OUT" '"streak": 1' "a no-movement cycle with no live session starts the streak"

# --- E2. a parked package resumes once the coordinator re-cuts the lane and removes the blocker
# The decision is recorded in the issue (SCOPE.json widened), the BLOCKER.md is
# removed, and the next cycle relaunches at the same tier with a re-cut scope
# commit on the branch. Until then, nothing relaunches.
OUT=$(fleet cycle --apply --json 2>/dev/null)
# Read at once: a parked package is skipped before the spawn, so no detached
# stub exists to write here later.
assert_not_contains "$(ls "$TMP/claude-log")" "T1.4.2" "a parked package with its BLOCKER.md still present is not relaunched"
node - "$TMP/gh/issues.json" <<'JS'
const fs = require('fs'); const f = process.argv[2]; const issues = JSON.parse(fs.readFileSync(f, 'utf8'));
const i = issues.find(x => x.number === 13);
i.body = i.body.replace('"allowedPaths":["src/**"]', '"allowedPaths":["src/**","docs/**"]');
fs.writeFileSync(f, JSON.stringify(issues, null, 2));
JS
rm -f "$TMP/worktrees/api-t1-4/BLOCKER.md"
export CLAUDE_STUB_MODE_T1_4=silent
# First, a lane the coordinator re-cut wrong: docs/** allowed but also forbidden. Refused, and retried next cycle.
node - "$TMP/gh/issues.json" <<'JS'
const fs = require('fs'); const f = process.argv[2]; const issues = JSON.parse(fs.readFileSync(f, 'utf8'));
const i = issues.find(x => x.number === 13);
i.body = i.body.replace('"forbiddenPaths":["contracts/**"]', '"forbiddenPaths":["contracts/**","docs/**"]');
fs.writeFileSync(f, JSON.stringify(issues, null, 2));
JS
OUT=$(fleet cycle --apply --json 2>/dev/null); EXIT=$?
assert_contains "$OUT" '"outcome": "unparked"' "the parked session is reaped as unparked once the blocker is gone"
assert_contains "$OUT" '"code": "unlaunchable"' "a re-cut lane that contradicts itself is refused, not launched"
# Read at once: the launch was refused before the spawn, so no detached stub
# exists to write here later.
assert_not_contains "$(ls "$TMP/claude-log")" "T1.4.2" "nothing launched into the refused lane"
assert_eq "retry" "$(node -e "console.log(require('$TMP/state/state.json').sessions[13].status)")" "the refused relaunch is held for retry, not lost"
node - "$TMP/gh/issues.json" <<'JS'
const fs = require('fs'); const f = process.argv[2]; const issues = JSON.parse(fs.readFileSync(f, 'utf8'));
const i = issues.find(x => x.number === 13);
i.body = i.body.replace('"forbiddenPaths":["contracts/**","docs/**"]', '"forbiddenPaths":["contracts/**"]');
fs.writeFileSync(f, JSON.stringify(issues, null, 2));
JS
# The refused cycle was the third without movement, so the fleet latched (correct: the queue
# was handed back). The coordinator resumes after recording the lane fix.
OUT=$(fleet cycle --apply --json 2>/dev/null); EXIT=$?
assert_eq 78 "$EXIT" "with a retry pending and three idle cycles the fleet is latched"
fleet resume --reason "fixture: lane re-cut, forbiddenPaths corrected" >/dev/null 2>&1
OUT=$(fleet cycle --apply --json 2>"$TMP/fixlane.err"); EXIT=$?
assert_eq 0 "$EXIT" "after resume the cycle after the lane fix exits 0 (stderr: $(head -c 200 "$TMP/fixlane.err" | tr '\n' ' '))"
assert_contains "$OUT" '"recut": true' "the relaunch re-cuts the committed SCOPE.json from the issue"
wait_exit 13-2 && _pass "the unparked relaunch ran" || _fail "the unparked relaunch ran" "no exit file 13-2"
assert_contains "$(git --git-dir "$TMP/remote.git" log --format=%s feat/t1-4-blocker | head -1)" "T1.4: scope re-cut" "the re-cut scope is committed and pushed on the branch"
assert_contains "$(git --git-dir "$TMP/remote.git" show feat/t1-4-blocker:.agentic/cells/feat/t1-4-blocker/SCOPE.json)" 'docs/**' "the committed lane is the widened one"
ARGV4=$(cat "$TMP/claude-log/T1.4.2.argv")
assert_not_contains "$ARGV4" "--model" "an unparked relaunch keeps its tier (no escalation)"
assert_contains "$ARGV4" "attempt 2" "the unparked relaunch is attempt 2"
assert_eq "2" "$(node -e "console.log(require('$TMP/state/state.json').dispatches['T1.4'].length)")" "unparking is a new dispatch"
assert_contains "$(node -e "console.log(JSON.stringify(require('$TMP/state/state.json').dispatches['T1.4'][1]))")" '"reason":"unparked"' "the dispatch records why"
# Settle: attempt 2 was silent; with maxEscalations 1 it hits the cap, so the fleet is idle from here.
OUT=$(fleet cycle --apply --json 2>/dev/null)
assert_contains "$OUT" '"code": "escalation-cap"' "the unparked package's silent run hits the escalation cap"

# --- F. idle cycles: no label writes, latch at the limit ---------------------
BEFORE=$(edits)
OUT=$(fleet cycle --apply --json 2>/dev/null); EXIT=$?
assert_eq "$BEFORE" "$(edits)" "an idle cycle writes no labels"
assert_contains "$OUT" '"outcome": "exhaustion"' "an idle cycle is exhaustion, with counts"
assert_contains "$OUT" '"wipFree"' "exhaustion carries the free-slot count"
assert_contains "$OUT" '"streak": 2' "the streak counts up from the last movement"
OUT=$(fleet cycle --apply --json 2>/dev/null); EXIT=$?
assert_eq 78 "$EXIT" "the cycle that reaches the limit exits 78"
assert_contains "$OUT" '"latched"' "the state is latched"
assert_contains "$OUT" 'consecutive cycles without movement' "the latch reason states the count"
OUT=$(fleet cycle --apply --json 2>"$TMP/errL"); EXIT=$?
assert_eq 78 "$EXIT" "a latched fleet refuses to run another cycle"
assert_contains "$OUT" '"code": "latched"' "the refusal names the latch"
OUT=$(fleet resume --reason "fixture: operator reviewed" 2>&1); EXIT=$?
assert_eq 0 "$EXIT" "resume exits 0"
assert_contains "$OUT" "latch cleared" "resume clears the latch"
OUT=$(fleet cycle --apply --json 2>/dev/null); EXIT=$?
assert_eq 0 "$EXIT" "after resume the cycle runs again"
OUT=$(fleet resume 2>&1); EXIT=$?
assert_ne 0 "$EXIT" "resume without --reason is refused"

# --- G. status is read-only and reflects the sessions -------------------------
OUT=$(fleet status 2>&1)
assert_contains "$OUT" "T1.1" "status lists the sessions"
assert_contains "$OUT" "attempt 2" "status shows the relaunched attempt"

# --- H. a truncated sync launches nothing ------------------------------------
BEFORE=$(edits); NLOG=$(ls "$TMP/claude-log" | wc -l | tr -d ' ')
OUT=$(SYNC_CELLS_PAGE_LIMIT=1 fleet cycle --apply --json 2>/dev/null); EXIT=$?
assert_eq 75 "$EXIT" "a sync that fills its page exits 75"
assert_contains "$OUT" '"code": "sync-failed"' "the abort is reported as an alarm"
assert_eq "$BEFORE" "$(edits)" "nothing was written after the aborted sync"
# Read at once: the cycle aborted at sync, before any launch, so no detached
# stub exists to write here later.
assert_eq "$NLOG" "$(ls "$TMP/claude-log" | wc -l | tr -d ' ')" "nothing was launched after the aborted sync"

# --- I. a live lock refuses; a dead one is taken over ------------------------
node -e "require('fs').writeFileSync('$TMP/state/cycle.lock', JSON.stringify({pid:process.ppid, host:require('os').hostname(), bootId:require('$(cd .. && pwd -P)/src/store.js').bootId(), startedAt:new Date().toISOString()}))"
OUT=$(fleet cycle --json 2>/dev/null); EXIT=$?
assert_eq 79 "$EXIT" "a lock held by a live process refuses the cycle"
rm -f "$TMP/state/cycle.lock"
node -e "require('fs').writeFileSync('$TMP/state/cycle.lock', JSON.stringify({pid:999999, host:require('os').hostname(), bootId:'x', startedAt:new Date().toISOString()}))"
OUT=$(fleet cycle --json 2>"$TMP/errK"); EXIT=$?
assert_eq 0 "$EXIT" "a stale lock is taken over"
assert_contains "$(cat "$TMP/errK")" "stale lock" "the takeover is logged"

# --- J. fleet launch narrows to one issue --------------------------------------
OUT=$(fleet launch 14 2>/dev/null); EXIT=$?
assert_contains "$OUT" '"launched": []' "fleet launch of an external worker's package launches nothing here"

# --- K. doctor runs and names what is missing ----------------------------------
OUT=$(fleet doctor 2>&1); EXIT=$?
assert_contains "$OUT" "ok    sync-cells.sh supports --emit-state" "doctor confirms the plugin version"
assert_contains "$OUT" "ok    sync-cells.sh supports --epic" "doctor confirms sync-cells can be scoped to the epic"
assert_contains "$OUT" "FAIL  scope + handoff hooks committed in acme/api" "doctor flags a target without committed hooks"
assert_ne 0 "$EXIT" "doctor exits non-zero when a check fails"

finish
