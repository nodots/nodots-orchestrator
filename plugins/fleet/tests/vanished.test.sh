#!/usr/bin/env bash
# A worker that dies without an exit file is an alarm, not movement.
#
# On a supervisor that kills the cycle's control group (systemd Type=oneshot
# with the default KillMode=control-group), every worker the cycle launched is
# killed when the cycle exits. The launcher's wrapper never writes the exit
# file, and the next cycle used to relaunch the package and report the
# relaunch as a `dispatch` movement, so the streak never rose.
#
# The fixture reproduces that: a real cycle launches a sleeping stub worker,
# the test SIGKILLs the worker's whole process group (what the control-group
# kill does), and the next cycles are checked.
set -uo pipefail
cd "$(dirname "$0")"
. ./lib.sh

HERE=$(pwd -P)
SRC="$(cd .. && pwd -P)/src/reap.js"
FLEET="$(cd .. && pwd -P)/bin/fleet.js"
PLUGIN="$(cd ../../agentic-work-packages && pwd -P)"
assert_file "$FLEET" "fleet.js exists"

TMP=$(mktemp -d)
PIDS=()
cleanup() { for p in "${PIDS[@]}"; do kill -KILL -- "-$p" 2>/dev/null; done; rm -rf "$TMP"; }
trap cleanup EXIT
TMP=$(cd "$TMP" && pwd -P)

js() { node -e "const r=require('$SRC'); $1"; }

# --- classify: the vanished row -----------------------------------------------
# A running record with a pid, no exit file: the process was spawned, and the
# wrapper writes the exit file on every exit it lives through.
R="{issue:12,id:'T1.2',branch:'feat/t1-2-x',status:'running',pid:4242,attempt:1,tier:'default',worktree:'$TMP/wt'}"
assert_eq "vanished relaunch worker-vanished" "$(js "const c=r.classify($R,{exitCode:null,logEmpty:false,livedMs:90000,logBytes:17}); console.log(c.outcome,c.next,c.reason)")" "no exit file from a spawned process is worker-vanished, relaunched"
assert_eq "vanished" "$(js "console.log(r.classify($R,{exitCode:null,logEmpty:true,livedMs:1000,logBytes:0}).outcome)")" "an empty log does not turn a vanished worker into crash-before-run"
assert_eq "4242 90 17" "$(js "const v=r.classify($R,{exitCode:null,logEmpty:false,livedMs:90000,logBytes:17}).vanished; console.log(v.pid,v.livedSeconds,v.logBytes)")" "the event carries the pid, how long it lived and the log size"
assert_eq "pr" "$(js "console.log(r.classify($R,{exitCode:null,pr:{number:5,state:'OPEN'}}).outcome)")" "a vanished worker that opened its PR is still the PR"
assert_eq "parked" "$(js "console.log(r.classify($R,{exitCode:null,blocker:{kind:'external',known:true}}).outcome)")" "a vanished worker that filed a BLOCKER is still parked"
assert_eq "escalate exit:3" "$(js "const c=r.classify($R,{exitCode:3,logEmpty:false}); console.log(c.outcome,c.reason)")" "an exit file present is classified exactly as before"
assert_eq "relaunch crash-before-run" "$(js "const c=r.classify({...$R,status:'launching'},{exitCode:null,logEmpty:false}); console.log(c.outcome,c.reason)")" "a record still at launching is crash-before-run, not vanished"
assert_eq "escalate timeout" "$(js "const c=r.classify({...$R,killedAt:'2026-11-02T00:00:00Z'},{exitCode:null,logEmpty:false,livedMs:9000000,logBytes:5}); console.log(c.outcome,c.reason)")" "a session reap killed on timeout (its group signal takes the wrapper) escalates as timeout, not vanished"
assert_eq "30 90" "$(js "const v=r.classify($R,{exitCode:null,logEmpty:false,livedMs:90000,lastWriteMs:30000,logBytes:17}).vanished; console.log(v.livedMinSeconds,v.livedSeconds)")" "lifetime is bounded by the last log write and the reap"

# --- reap: the repeat rule ----------------------------------------------------
mkdir -p "$TMP/u/logs" "$TMP/u/wt"
OUT=$(node - "$SRC" "$TMP/u" <<'JS'
const r = require(process.argv[2]); const T = process.argv[3];
const cfg = { sessionTimeoutMinutes: 60, killGraceSeconds: 60 };
const rec = () => ({ issue: 12, id: 'T1.2', branch: 'b', status: 'running', attempt: 1, tier: 'default', worktree: T + '/wt', pid: 999999, procStart: null, logPath: T + '/logs/12-1.log', exitPath: T + '/logs/12-1.exit', startedAt: new Date(Date.now() - 5000).toISOString() });
const state = { sessions: { 12: rec() } };
const fs = require('fs');
const t0 = Date.now();
fs.writeFileSync(T + '/logs/12-1.log', '0123456789');
const a = r.reap(cfg, state, [], t0);
state.sessions[12] = rec();
fs.appendFileSync(T + '/logs/12-1.log', 'abcdefg');           // the relaunch appends to the same log
const b = r.reap(cfg, state, [], t0 + 30 * 60000);           // inside the window
state.sessions[12] = rec();
const c = r.reap(cfg, state, [], t0 + 30 * 60000 + 61 * 60000); // first two have aged out of the window
const show = o => `${o.reaped[0].outcome}/${o.reaped[0].reason}/${o.requests.length}`;
console.log(show(a), show(b), show(c), state.sessions[12].status);
console.log(a.reaped[0].vanished.logBytes, b.reaped[0].vanished.logBytes);
JS
)
assert_eq "vanished/worker-vanished/1 vanished/worker-vanished-repeat/0 vanished/worker-vanished/1 closed" "$(printf '%s\n' "$OUT" | head -1)" "the second vanishing within sessionTimeoutMinutes asks for no relaunch; one outside the window does"
assert_eq "10 7" "$(printf '%s\n' "$OUT" | sed -n 2p)" "the log size is this run's bytes, not the attempt's appended total"

# --- the cycle, end to end ------------------------------------------------------
git init -q --bare -b main "$TMP/remote.git"
git clone -q "$TMP/remote.git" "$TMP/clone" 2>/dev/null
git -C "$TMP/clone" checkout -q -b main 2>/dev/null || true
git -C "$TMP/clone" config user.email f@example.invalid; git -C "$TMP/clone" config user.name fixture
printf '# api\n' > "$TMP/clone/README.md"
git -C "$TMP/clone" add -A && git -C "$TMP/clone" commit -qm init && git -C "$TMP/clone" push -q -u origin main

STUB="$TMP/stub"; mkdir -p "$STUB" "$TMP/gh" "$TMP/claude-log"
cp "$HERE/stubs/gh.js" "$STUB/gh.js"
printf '#!/usr/bin/env bash\nexec node "%s/gh.js" "$@"\n' "$STUB" > "$STUB/gh"; chmod +x "$STUB/gh"
cp "$HERE/stubs/claude.sh" "$STUB/claude"; chmod +x "$STUB/claude"
export GH_STUB_DIR="$TMP/gh" GH_STUB_REMOTE="$TMP/remote.git" CLAUDE_STUB_LOG="$TMP/claude-log" CLAUDE_STUB_TARGET="acme/api"
export GH_BIN="$STUB/gh" CLAUDE_BIN="$STUB/claude"
export CLAUDE_CONFIG_FILE="$TMP/claude.json"
node -e "require('fs').writeFileSync('$TMP/claude.json', JSON.stringify({projects:{['$TMP/clone']:{hasTrustDialogAccepted:true}}}))"
export CLAUDE_STUB_MODE_T1_1=sleep CLAUDE_STUB_SLEEP=300

BODY=$(printf '**Part of** #1 · **Phase 1 · x** · **Repo:** `acme/api`\n\n## Goal\nx\n\n### SCOPE.json\n```json\n{"feature":"f","branch":"feat/t1-1-first","allowedPaths":["src/**"],"forbiddenPaths":[],"dependsOn":[],"execution":{"model":"default","pattern":"solo"}}\n```\n')
node - "$TMP/gh" "$BODY" <<'JS'
const fs = require('fs'); const [dir, body] = process.argv.slice(2);
fs.writeFileSync(`${dir}/issues.json`, JSON.stringify([
  { number: 1, title: 'Epic: program T', body: '', state: 'OPEN', labels: ['epic'] },
  { number: 10, title: 'T1.1 First thing', body, state: 'OPEN', labels: ['agent-ready', 'cell:queued', 'worker:a'] },
], null, 2));
fs.writeFileSync(`${dir}/prs.json`, '[]');
fs.writeFileSync(`${dir}/labels.json`, '{}'); fs.writeFileSync(`${dir}/comments.json`, '{}'); fs.writeFileSync(`${dir}/writes.log`, '');
JS

cat > "$TMP/fleet.config.json" <<JSON
{
  "repo": "acme/host", "epic": 1,
  "targets": [{ "repo": "acme/api", "localPath": "$TMP/clone", "defaultBranch": "main" }],
  "workers": { "a": { "mode": "local" } },
  "wipCap": 2, "worktreesDir": "$TMP/worktrees", "stateDir": "$TMP/state",
  "pluginRoot": "$PLUGIN", "maxEscalations": 1, "noMovementLimit": 5, "sessionTimeoutMinutes": 30,
  "models": { "cheapest": "haiku", "default": null, "strongest": "opus" }
}
JSON
fleet() { node "$FLEET" "$@" --config "$TMP/fleet.config.json"; }
st() { node -e "const s=require('$TMP/state/state.json'); console.log($1)"; }
# What KillMode=control-group does to a detached worker: SIGKILL to its whole
# process group, wrapper included, so no exit file is written.
vanish() {
  local pid; pid=$(st "s.sessions[10].pid")
  PIDS+=("$pid")
  kill -KILL -- "-$pid" 2>/dev/null
  local i=0; while kill -0 "$pid" 2>/dev/null && [ $i -lt 40 ]; do sleep 0.25; i=$((i + 1)); done
  ! kill -0 "$pid" 2>/dev/null
}

# 1. The first cycle launches the worker: a real dispatch.
OUT=$(fleet cycle --apply --json 2>/dev/null); EXIT=$?
assert_eq 0 "$EXIT" "the first cycle exits 0"
assert_contains "$OUT" '"type": "dispatch"' "the first launch is a dispatch movement"
assert_eq "0" "$(st s.streak)" "the streak is 0 after movement"
vanish && _pass "the worker is killed with its process group" || _fail "the worker is killed with its process group" "still alive"
[ -f "$TMP/state/logs/10-1.exit" ] && _fail "the killed worker left no exit file" "exit file present" || _pass "the killed worker left no exit file"

# 2. The next cycle: worker-vanished, a relaunch, an alarm, no movement.
OUT=$(fleet cycle --apply --json 2>/dev/null); EXIT=$?
assert_contains "$OUT" '"outcome": "vanished"' "the dead session is reaped as vanished"
assert_contains "$OUT" '"code": "worker-vanished"' "the cycle raises worker-vanished"
DETAIL=$(node -e "const r=JSON.parse(require('fs').readFileSync(0,'utf8')); const a=r.alarms.find(x=>x.code==='worker-vanished'); console.log(a ? a.issue + ' ' + a.detail : 'none')" <<<"$OUT")
assert_contains "$DETAIL" "10 T1.1" "the alarm names the package"
assert_contains "$DETAIL" "pid " "the alarm names the pid"
assert_contains "$DETAIL" "lived " "the alarm says how long it lived"
assert_contains "$DETAIL" "log " "the alarm gives the log size"
assert_contains "$OUT" '"launched": [' "the package is relaunched"
assert_eq "1" "$(node -e "const r=JSON.parse(require('fs').readFileSync(0,'utf8')); console.log(r.launched.filter(l=>l.issue===10).length)" <<<"$OUT")" "exactly one relaunch"
assert_eq "0" "$(node -e "const r=JSON.parse(require('fs').readFileSync(0,'utf8')); console.log(r.movement.length)" <<<"$OUT")" "the relaunch is not movement"
assert_contains "$OUT" '"outcome": "alarm"' "the cycle outcome is alarm"
assert_eq "1" "$(st s.streak)" "the no-movement streak rises"
assert_eq "1" "$(st "s.dispatches['T1.1'].length")" "a relaunch after a vanishing is not a new dispatch"

# 3. It vanishes again within sessionTimeoutMinutes: held, nothing launched.
vanish && _pass "the relaunched worker is killed too" || _fail "the relaunched worker is killed too" "still alive"
NLOG=$(ls "$TMP/claude-log" | grep -c '^T1.1\..*\.argv$')
OUT=$(fleet cycle --apply --json 2>/dev/null); EXIT=$?
assert_contains "$OUT" '"code": "worker-vanished-repeat"' "the second vanishing raises worker-vanished-repeat"
assert_contains "$OUT" '"launched": []' "nothing is launched a third time"
assert_eq "$NLOG" "$(ls "$TMP/claude-log" | grep -c '^T1.1\..*\.argv$')" "the stub worker was not started again"
assert_contains "$OUT" '"outcome": "alarm"' "the hold is an alarm"
assert_eq "2" "$(st s.streak)" "the streak keeps rising"

# 4. The held package stays held on the next cycle.
OUT=$(fleet cycle --apply --json 2>/dev/null); EXIT=$?
assert_contains "$OUT" '"launched": []' "a held package is not relaunched by a later cycle"
assert_eq "3" "$(st s.streak)" "idle cycles after the hold still count toward the latch"

finish
