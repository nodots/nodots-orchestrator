#!/usr/bin/env bash
# Fixture test for require-coordinator.js (X0.2).
#
# In a session with FLEET_WORKER_ID set, the PreToolUse Bash hook refuses a
# command that files an issue, writes a coordinator label (agent-ready, cell:*,
# worker:*), or edits an issue's body or title. Without the variable it does
# nothing. A hook that cannot evaluate fails open, and says so.
set -uo pipefail
cd "$(dirname "$0")"
. ./lib.sh

HOOK_SRC="$(cd ../hooks && pwd -P)/require-coordinator.js"
assert_file "$HOOK_SRC" "the hook under test exists"

TMPROOT=$(mktemp -d)
trap 'rm -rf "$TMPROOT"' EXIT
ERRFILE="$TMPROOT/stderr"

# run_cmd <worker-id|-> <command>  -> sets EXIT, OUT, ERR
run_cmd() {
  local worker="$1" cmd="$2" json
  json=$(node -e 'process.stdout.write(JSON.stringify({hook_event_name:"PreToolUse",tool_name:"Bash",tool_input:{command:process.argv[1]}}))' "$cmd")
  if [ "$worker" = "-" ]; then
    OUT=$(printf '%s' "$json" | env -u FLEET_WORKER_ID node "$HOOK_SRC" 2>"$ERRFILE")
  else
    OUT=$(printf '%s' "$json" | FLEET_WORKER_ID="$worker" node "$HOOK_SRC" 2>"$ERRFILE")
  fi
  EXIT=$?
  ERR=$(cat "$ERRFILE")
}

refused() {
  run_cmd a "$1"
  assert_eq 2 "$EXIT" "refused · $1"
  assert_contains "$ERR" "BLOCKER.md" "refused · names BLOCKER.md · $1"
}
allowed() {
  run_cmd a "$1"
  assert_eq 0 "$EXIT" "allowed · $1"
}
passes_unset() {
  run_cmd - "$1"
  assert_eq 0 "$EXIT" "unset   · $1"
}

REFUSED=(
  'gh issue create --repo o/r --title x --label agent-ready'
  'gh issue create --repo o/r --title x'
  'gh issue edit 5 --add-label worker:a'
  'gh issue edit 5 --remove-label cell:queued'
  'gh issue edit 5 --add-label agent-ready'
  'gh issue edit 5 --add-label=bug,worker:a'
  'gh issue edit 5 --remove-label=cell:done'
  'gh issue edit 5 --add-label "bug,cell:queued"'
  'gh issue edit 5 --body-file b.md'
  'gh issue edit 5 -F b.md'
  'gh issue edit 5 --body x'
  'gh issue edit 5 -b x'
  'gh issue edit 5 --title x'
  'gh issue edit 5 -t x'
  'gh issue edit 5 --body=x'
  'gh api -X POST repos/o/r/issues/5/labels -f labels[]=agent-ready'
  'gh api --method DELETE repos/o/r/issues/5/labels/worker:a'
  'gh api --method=PATCH repos/o/r/issues/5/labels'
  'gh api repos/o/r/issues/5/labels -f labels[]=worker:a'
  'gh api repos/o/r/issues/5 -F labels[]=agent-ready'
  'echo ok && gh issue create -t x'
  'echo ok; gh issue edit 5 --add-label worker:a'
  'true || gh issue create -t x'
  'echo ok | gh issue create -t x'
  $'echo ok\ngh issue create -t x'
)
ALLOWED=(
  'gh pr create --title x --body y'
  'gh issue view 5'
  'gh issue comment 5 --body x'
  'gh issue edit 5 --add-label bug'
  'gh issue edit 5 --add-label=bug,docs'
  'gh api repos/o/r/issues/5'
  'gh api -X GET repos/o/r/issues/5/labels'
)

for c in "${REFUSED[@]}"; do refused "$c"; done
for c in "${ALLOWED[@]}"; do allowed "$c"; done
for c in "${REFUSED[@]}"; do passes_unset "$c"; done

# the message names the hook and the command it matched
run_cmd a 'gh issue create --title x'
assert_contains "$ERR" "require-coordinator" "the refusal names the hook"
assert_contains "$ERR" "gh issue create --title x" "the refusal names the matched command"
assert_contains "$ERR" "the coordinator files it" "the refusal says who files"
assert_empty "$OUT" "the refusal writes nothing to stdout"

# an empty FLEET_WORKER_ID is unset
run_cmd "" 'gh issue create --title x'
assert_eq 0 "$EXIT" "an empty FLEET_WORKER_ID is not a worker session"

# fail open, and loud
OUT=$(printf 'not json' | FLEET_WORKER_ID=a node "$HOOK_SRC" 2>"$ERRFILE"); EXIT=$?
ERR=$(cat "$ERRFILE")
assert_eq 0 "$EXIT" "malformed hook input fails open"
assert_contains "$ERR" "require-coordinator" "malformed hook input is reported on stderr"

OUT=$(printf '{"tool_input":{}}' | FLEET_WORKER_ID=a node "$HOOK_SRC" 2>"$ERRFILE"); EXIT=$?
assert_eq 0 "$EXIT" "an event with no command passes"

# wiring and copies
if node -e '
  const s = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
  const pre = (s.hooks && s.hooks.PreToolUse) || [];
  const ok = pre.some(e => e.matcher === "Bash" &&
    (e.hooks || []).some(h => (h.command || "").includes("require-coordinator.js")));
  process.exit(ok ? 0 : 1);
' ../../../../hooks/hooks.json; then
  _pass "hooks.json wires PreToolUse Bash to require-coordinator.js"
else
  _fail "hooks.json wires PreToolUse Bash to require-coordinator.js" "no such matcher"
fi

if node -e '
  const s = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
  const pre = (s.hooks && s.hooks.PreToolUse) || [];
  const ok = pre.some(e => e.matcher === "Bash" &&
    (e.hooks || []).some(h => (h.command || "").includes("require-coordinator.js")));
  process.exit(ok ? 0 : 1);
' ../settings-snippet.json; then
  _pass "settings-snippet.json wires PreToolUse Bash to require-coordinator.js"
else
  _fail "settings-snippet.json wires PreToolUse Bash to require-coordinator.js" "no such matcher"
fi

if diff -q "$HOOK_SRC" ../../../../hooks/require-coordinator.js >/dev/null 2>&1; then
  _pass "the plugin and asset copies of the hook are byte-identical"
else
  _fail "the plugin and asset copies of the hook are byte-identical" "they differ"
fi

finish
