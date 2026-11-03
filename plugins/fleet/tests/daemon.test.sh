#!/usr/bin/env bash
# Fixture test for `fleet daemon`, on cycle.test.sh's harness: a real git
# remote, the real plugin scripts, the stateful gh stub and the claude stub,
# with two programs (epics #1 and #2) in one host repo and one config each.
#
# What is proved: each config cycles at start; a worker's exit file triggers a
# cycle for its own config inside the coalescing window and none for the other;
# exits close together coalesce into one cycle; triggers that arrive during a
# running cycle produce exactly one follow-up; SIGTERM during a cycle lets it
# finish, exits 0 and leaves the live worker running; an interval runs one
# cycle per interval per config; a latched config stops cycling until
# `fleet resume` while the other keeps cycling.
#
# Timings are scaled down through the daemon's test-only environment variables
# FLEET_DAEMON_INTERVAL_MS, FLEET_DAEMON_COALESCE_MS and FLEET_DAEMON_POLL_MS.
set -uo pipefail
cd "$(dirname "$0")"
. ./lib.sh

HERE=$(pwd -P)
FLEET="$(cd .. && pwd -P)/bin/fleet.js"
PLUGIN="$(cd ../../agentic-work-packages && pwd -P)"
assert_file "$FLEET" "fleet.js exists"

TMP=$(mktemp -d)
TMP=$(cd "$TMP" && pwd -P)
DPID=""
cleanup() {
  [ -n "$DPID" ] && kill -KILL "$DPID" 2>/dev/null
  # Stub workers and anything else started under the fixture directory.
  pkill -KILL -f -- "$TMP/" 2>/dev/null
  rm -rf "$TMP"
}
trap cleanup EXIT

# --- a real remote and clone --------------------------------------------------
git init -q --bare -b main "$TMP/remote.git"
git clone -q "$TMP/remote.git" "$TMP/clone" 2>/dev/null
git -C "$TMP/clone" checkout -q -b main 2>/dev/null || true
git -C "$TMP/clone" config user.email f@example.invalid; git -C "$TMP/clone" config user.name fixture
printf '# api\n' > "$TMP/clone/README.md"
git -C "$TMP/clone" add -A && git -C "$TMP/clone" commit -qm init && git -C "$TMP/clone" push -q -u origin main

# --- stubs -------------------------------------------------------------------
# gh: the shared stub behind a wrapper that sleeps $TMP/gh-delay seconds per
# call when that file exists, so a test can hold a cycle open.
# claude: the shared stub behind a wrapper that holds each worker until
# $TMP/hold/<package>.release exists, so a test decides when a worker exits.
STUB="$TMP/stub"; mkdir -p "$STUB" "$TMP/gh" "$TMP/claude-log" "$TMP/hold"
cp "$HERE/stubs/gh.js" "$STUB/gh.js"
cat > "$STUB/gh" <<SH
#!/usr/bin/env bash
[ -f "$TMP/gh-delay" ] && sleep "\$(cat "$TMP/gh-delay")"
exec node "$STUB/gh.js" "\$@"
SH
chmod +x "$STUB/gh"
cp "$HERE/stubs/claude.sh" "$STUB/claude.sh"
cat > "$STUB/claude" <<SH
#!/usr/bin/env bash
until [ -e "$TMP/hold/\${FLEET_PACKAGE:-x}.release" ]; do sleep 0.1; done
exec bash "$STUB/claude.sh" "\$@"
SH
chmod +x "$STUB/claude"
export GH_STUB_DIR="$TMP/gh" GH_STUB_REMOTE="$TMP/remote.git" CLAUDE_STUB_LOG="$TMP/claude-log" CLAUDE_STUB_TARGET="acme/api"
export GH_BIN="$STUB/gh" CLAUDE_BIN="$STUB/claude"
export CLAUDE_CONFIG_FILE="$TMP/claude.json"
node -e "require('fs').writeFileSync('$TMP/claude.json', JSON.stringify({projects:{['$TMP/clone']:{hasTrustDialogAccepted:true}}}))"
export CLAUDE_STUB_MODE_A1_1=silent CLAUDE_STUB_MODE_A1_2=silent

scope_body() { # epic branch
  printf '**Part of** #%s · **Phase 1 · x** · **Repo:** `acme/api`\n\n## Goal\nx\n\n### SCOPE.json\n```json\n{"feature":"f","branch":"%s","allowedPaths":["src/**"],"forbiddenPaths":["contracts/**"],"dependsOn":[],"execution":{"model":"default","pattern":"solo"}}\n```\n' "$1" "$2"
}
node - "$TMP/gh" "$(scope_body 1 feat/a1-1-exits)" "$(scope_body 1 feat/a1-2-stays)" <<'JS'
const fs = require('fs'); const [dir, a11, a12] = process.argv.slice(2);
fs.writeFileSync(`${dir}/issues.json`, JSON.stringify([
  { number: 1, title: 'Epic: program A', body: '', state: 'OPEN', labels: ['epic'] },
  { number: 2, title: 'Epic: program B', body: '', state: 'OPEN', labels: ['epic'] },
  { number: 10, title: 'A1.1 Exits when released', body: a11, state: 'OPEN', labels: ['agent-ready', 'cell:queued', 'worker:a'] },
  { number: 11, title: 'A1.2 Stays alive', body: a12, state: 'OPEN', labels: ['agent-ready', 'cell:queued', 'worker:a'] },
], null, 2));
fs.writeFileSync(`${dir}/prs.json`, '[]');
fs.writeFileSync(`${dir}/labels.json`, '{}'); fs.writeFileSync(`${dir}/comments.json`, '{}'); fs.writeFileSync(`${dir}/writes.log`, '');
JS

config() { # file epic name noMovementLimit
  cat > "$1" <<JSON
{
  "repo": "acme/host", "epic": $2,
  "targets": [{ "repo": "acme/api", "localPath": "$TMP/clone", "defaultBranch": "main" }],
  "workers": { "a": { "mode": "local" } },
  "wipCap": 2, "worktreesDir": "$TMP/wt-$3", "stateDir": "$TMP/state-$3",
  "pluginRoot": "$PLUGIN", "maxEscalations": 0, "noMovementLimit": $4, "sessionTimeoutMinutes": 60,
  "models": { "cheapest": "haiku", "default": null, "strongest": "opus" }
}
JSON
}
CA="$TMP/a.json"; CB="$TMP/b.json"
config "$CA" 1 a 100
config "$CB" 2 b 100

# count <log> <config file>: cycle lines for that config in a daemon's stdout.
count() { grep -cE "^[0-9TZ:.-]+ $(printf '%s' "$2" | sed 's/[.]/\\./g') (MOVEMENT|EXHAUSTION|ALARM) [0-9A-Za-z-]+$" "$1" || true; }
# wait_for <seconds> <command...>: poll every 0.1s until the command succeeds.
wait_for() { local n=$(( $1 * 10 )) i=0; shift; until "$@"; do i=$((i + 1)); [ $i -ge $n ] && return 1; sleep 0.1; done; }
count_ge() { [ "$(count "$1" "$2")" -ge "$3" ]; }
now_ms() { node -e 'process.stdout.write(String(Date.now()))'; }
# Start time (ms) of the newest cycle report of a config's state dir.
last_start_ms() { node -e '
  const fs = require("fs"), d = process.argv[1] + "/cycles";
  const at = fs.readdirSync(d).map(f => JSON.parse(fs.readFileSync(d + "/" + f, "utf8")).at).sort();
  process.stdout.write(String(Date.parse(at[at.length - 1])));' "$1"; }
alive() { kill -0 "$1" 2>/dev/null; }
locked() { [ -f "$1/cycle.lock" ]; }

start_daemon() { # log; env set by caller
  node "$FLEET" daemon --config "$CA" --config "$CB" >"$1" 2>"$1.err" &
  DPID=$!
}

# --- usage -------------------------------------------------------------------
node "$FLEET" daemon --config "$CA" --config "$CA" >/dev/null 2>"$TMP/dup.err"; EXIT=$?
assert_eq 64 "$EXIT" "the same config twice is a usage error"
node "$FLEET" daemon --config "$CA" --interval nope >/dev/null 2>&1; EXIT=$?
assert_eq 64 "$EXIT" "a non-numeric --interval is a usage error"
node "$FLEET" daemon --config >/dev/null 2>&1; EXIT=$?
assert_eq 64 "$EXIT" "--config with no file is a usage error, not a crash"
node "$FLEET" daemon --config "$CA" --interval 40000 >/dev/null 2>"$TMP/big.err"; EXIT=$?
assert_eq 64 "$EXIT" "an interval past the timer limit is a usage error, not a 1ms timer"
assert_contains "$(cat "$TMP/big.err")" "timer limit" "the refusal says why"

# =============================================================================
# Run 1: exit-file triggers, coalescing, no overlap, SIGTERM.
# The interval is long, so every cycle after the first is an exit trigger.
# =============================================================================
W=1500
export FLEET_DAEMON_INTERVAL_MS=600000 FLEET_DAEMON_COALESCE_MS=$W FLEET_DAEMON_POLL_MS=100
L1="$TMP/run1.log"
start_daemon "$L1"
wait_for 60 count_ge "$L1" "$CA" 1 && _pass "config A runs a cycle at start" || _fail "config A runs a cycle at start" "$(cat "$L1" "$L1.err")"
wait_for 60 count_ge "$L1" "$CB" 1 && _pass "config B runs a cycle at start" || _fail "config B runs a cycle at start" "$(cat "$L1" "$L1.err")"
assert_contains "$(cat "$L1")" " $CA MOVEMENT " "A's first cycle launched its two workers (movement)"
assert_eq "1" "$(count "$L1" "$CB")" "B has one cycle"
P12=$(node -e "process.stdout.write(String(require('$TMP/state-a/state.json').sessions[11].pid))")
alive "$P12" && _pass "A1.2's worker is running" || _fail "A1.2's worker is running" "pid $P12"
sleep 0.5
A0=$(count "$L1" "$CA"); B0=$(count "$L1" "$CB")

# --- AC1: a worker's exit triggers its own config's cycle, inside the window ---
touch "$TMP/hold/A1.1.release"
wait_for 20 test -f "$TMP/state-a/logs/10-1.exit" && _pass "A1.1's worker exited and wrote its exit file" || _fail "A1.1's worker exited and wrote its exit file" "no 10-1.exit"
EXIT_MS=$(now_ms)
wait_for 30 count_ge "$L1" "$CA" $((A0 + 1)) && _pass "the exit triggered a cycle for A" || _fail "the exit triggered a cycle for A" "$(cat "$L1")"
LAG=$(( $(last_start_ms "$TMP/state-a") - EXIT_MS ))
[ "$LAG" -le $((W + 1000)) ] && _pass "A's cycle started inside the coalescing window (${LAG}ms after the exit; window ${W}ms)" || _fail "A's cycle started inside the coalescing window" "${LAG}ms after the exit; window ${W}ms"
sleep 1
assert_eq "$((A0 + 1))" "$(count "$L1" "$CA")" "one exit, one cycle for A"
assert_eq "$B0" "$(count "$L1" "$CB")" "A's worker exit triggered no cycle for B"

# --- coalescing: exits close together are one cycle ---------------------------
A1=$(count "$L1" "$CA")
printf '0\n' > "$TMP/state-a/logs/90-1.exit"; sleep 0.4
printf '0\n' > "$TMP/state-a/logs/91-1.exit"; sleep 0.4
printf '0\n' > "$TMP/state-a/logs/92-1.exit"
wait_for 30 count_ge "$L1" "$CA" $((A1 + 1)) && _pass "a burst of exits triggered a cycle" || _fail "a burst of exits triggered a cycle" "$(cat "$L1")"
sleep $(( W / 1000 + 3 ))
assert_eq "$((A1 + 1))" "$(count "$L1" "$CA")" "three exits inside one window coalesced into one cycle"
assert_eq "$B0" "$(count "$L1" "$CB")" "and none for B"

# --- an exit file rewritten under the same name is a new exit ------------------
# A relaunch that keeps its attempt number writes the same <issue>-<attempt>.exit.
A1=$(count "$L1" "$CA")
printf '0\n' > "$TMP/state-a/logs/90-1.exit.tmp" && mv "$TMP/state-a/logs/90-1.exit.tmp" "$TMP/state-a/logs/90-1.exit"
wait_for 30 count_ge "$L1" "$CA" $((A1 + 1)) && _pass "a rewritten exit file triggered a cycle" || _fail "a rewritten exit file triggered a cycle" "$(cat "$L1")"
sleep $(( W / 1000 + 2 ))

# --- AC2 (second half): triggers during a running cycle run exactly one follow-up
A2=$(count "$L1" "$CA")
printf '0.6\n' > "$TMP/gh-delay"
printf '0\n' > "$TMP/state-a/logs/93-1.exit"
wait_for 20 locked "$TMP/state-a" && _pass "a slow cycle for A is running" || _fail "a slow cycle for A is running" "no lock"
printf '0\n' > "$TMP/state-a/logs/94-1.exit"; sleep $(( W / 1000 + 1 ))
locked "$TMP/state-a" && _pass "a trigger arrived while A's cycle was running" || _fail "a trigger arrived while A's cycle was running" "the cycle ended first; raise gh-delay"
printf '0\n' > "$TMP/state-a/logs/95-1.exit"; sleep $(( W / 1000 + 1 ))
locked "$TMP/state-a" && _pass "a second trigger arrived while the same cycle was running" || _fail "a second trigger arrived while the same cycle was running" "the cycle ended first; raise gh-delay"
assert_eq "$A2" "$(count "$L1" "$CA")" "nothing completed while the first slow cycle ran (no overlap)"
rm -f "$TMP/gh-delay"
wait_for 60 count_ge "$L1" "$CA" $((A2 + 2)) && _pass "the queued trigger ran a follow-up cycle" || _fail "the queued trigger ran a follow-up cycle" "$(cat "$L1")"
sleep $(( W / 1000 + 3 ))
assert_eq "$((A2 + 2))" "$(count "$L1" "$CA")" "two triggers during a running cycle ran exactly one follow-up"

# --- AC4: SIGTERM during a cycle lets it finish and exits 0; workers live on ---
A3=$(count "$L1" "$CA")
printf '0.6\n' > "$TMP/gh-delay"
printf '0\n' > "$TMP/state-a/logs/96-1.exit"
wait_for 20 locked "$TMP/state-a" && _pass "a slow cycle for A is running before SIGTERM" || _fail "a slow cycle for A is running before SIGTERM" "no lock"
kill -TERM "$DPID"
sleep 0.5
alive "$DPID" && _pass "the daemon waits for the running cycle after SIGTERM" || _fail "the daemon waits for the running cycle after SIGTERM" "it exited at once"
wait "$DPID"; EXIT=$?; DPID=""
rm -f "$TMP/gh-delay"
assert_eq 0 "$EXIT" "the daemon exits 0 on SIGTERM"
assert_eq "$((A3 + 1))" "$(count "$L1" "$CA")" "the cycle in progress finished and reported its line"
locked "$TMP/state-a" && _fail "the finished cycle released its lock" "cycle.lock remains" || _pass "the finished cycle released its lock"
alive "$P12" && _pass "A1.2's worker (pid $P12) was not signalled and is still running" || _fail "A1.2's worker was not signalled" "pid $P12 is gone"
[ -f "$TMP/state-a/logs/11-1.exit" ] && _fail "A1.2's worker has not exited" "11-1.exit exists" || _pass "A1.2's worker has not exited"
assert_contains "$(cat "$L1")" "daemon stopping on SIGTERM; waiting for the cycle in progress: $CA" "the daemon logs that it is stopping and what it waits for"

# =============================================================================
# Run 2: the interval, and the latch.
# B latches after two idle cycles; A1.2's live worker keeps A off the streak.
# =============================================================================
node "$FLEET" resume --reason "fixture: reset B's streak" --config "$CB" >/dev/null 2>&1
config "$CB" 2 b 2
I=4000
export FLEET_DAEMON_INTERVAL_MS=$I FLEET_DAEMON_COALESCE_MS=500
L2="$TMP/run2.log"
T0=$(now_ms)
start_daemon "$L2"
# Cycles start at 0, I, 2I and 3I; stop looking at 3.5I.
sleep 0.5
wait_for 30 count_ge "$L2" "$CA" 1 || true
sleep $(( (7 * I / 2 - ($(now_ms) - T0)) / 1000 ))
# A cycle's report is written when it ends; let the one started at 3I finish.
wait_for 30 eval '! locked "$TMP/state-a" && ! locked "$TMP/state-b"' || true
# starts <stateDir>: start times of the cycles that began in [T0, T0 + 3.5I], comma-separated.
starts() { node -e '
  const fs = require("fs"), d = process.argv[1] + "/cycles", t0 = Number(process.argv[2]), end = t0 + 3.5 * Number(process.argv[3]);
  process.stdout.write(fs.readdirSync(d).map(f => Date.parse(JSON.parse(fs.readFileSync(d + "/" + f, "utf8")).at)).filter(x => x >= t0 && x <= end).sort((a, b) => a - b).join(","));' "$1" "$T0" "$I"; }
SA=$(starts "$TMP/state-a")
NA=$(printf '%s' "$SA" | tr ',' '\n' | grep -c . || true); NB=$(count "$L2" "$CB")
assert_eq 4 "$NA" "an interval of ${I}ms ran one cycle per interval for A over 3.5 intervals (starts: $SA)"
GAPS=$(node -e 'const s = process.argv[1].split(",").map(Number); const g = s.slice(1).map((x, i) => x - s[i]); process.stdout.write(g.every(x => Math.abs(x - Number(process.argv[2])) < 1000) ? "ok" : JSON.stringify(g));' "$SA" "$I")
assert_eq ok "$GAPS" "A's cycles start one interval apart"
assert_eq 2 "$NB" "B ran two cycles (at 0 and I), latched, and ran no more"
assert_eq 1 "$(grep -c " $CB LATCHED" "$L2" || true)" "B's latch is logged once, not every interval"
assert_contains "$(node -e "console.log(JSON.stringify(require('$TMP/state-b/state.json').latched))")" "consecutive cycles without movement" "B's state is latched"

# --- AC3: resume lets B cycle again; A keeps cycling meanwhile ---------------
node "$FLEET" resume --reason "fixture: operator reviewed B" --config "$CB" >/dev/null 2>&1
wait_for 10 count_ge "$L2" "$CB" 3 && _pass "after fleet resume B cycles again" || _fail "after fleet resume B cycles again" "$(cat "$L2")"
assert_contains "$(cat "$L2")" " $CB RESUMED" "the resume is logged"
AFTER_LATCH=$(sed -n "/ $(printf '%s' "$CB" | sed 's/[./]/\\&/g') LATCHED/,/ $(printf '%s' "$CB" | sed 's/[./]/\\&/g') RESUMED/p" "$L2" | grep -c " $CA \(MOVEMENT\|EXHAUSTION\|ALARM\) " || true)
[ "$AFTER_LATCH" -ge 1 ] && _pass "A kept cycling while B was latched ($AFTER_LATCH cycle(s) between B's latch and its resume)" || _fail "A kept cycling while B was latched" "$(cat "$L2")"

kill -TERM "$DPID"; wait "$DPID"; EXIT=$?; DPID=""
assert_eq 0 "$EXIT" "the daemon exits 0 on SIGTERM between cycles"
alive "$P12" && _pass "A1.2's worker still runs after the second daemon stops" || _fail "A1.2's worker still runs after the second daemon stops" "pid $P12 is gone"

finish
