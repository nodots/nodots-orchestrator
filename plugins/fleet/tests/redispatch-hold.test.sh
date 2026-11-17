#!/usr/bin/env bash
# A package without agent-ready is not re-dispatched.
#
# What is proved: a worker that exits silent while its issue lacks agent-ready
# is reaped, and its escalation is held: no second attempt, the session kept
# for retry, the report names the hold. The hold lasts across cycles. Once the
# label is back, the held escalation is launched one tier up.
set -uo pipefail
cd "$(dirname "$0")"
. ./lib.sh

HERE=$(pwd -P)
FLEET="$(cd .. && pwd -P)/bin/fleet.js"
PLUGIN="$(cd ../../agentic-work-packages && pwd -P)"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
TMP=$(cd "$TMP" && pwd -P)

git init -q --bare -b main "$TMP/remote.git"
git clone -q "$TMP/remote.git" "$TMP/clone" 2>/dev/null
git -C "$TMP/clone" checkout -q -b main 2>/dev/null || true
git -C "$TMP/clone" config user.email f@example.invalid; git -C "$TMP/clone" config user.name fixture
printf '# api\n' > "$TMP/clone/README.md"
git -C "$TMP/clone" add -A && git -C "$TMP/clone" commit -qm init && git -C "$TMP/clone" push -q -u origin main
fixture_standards "$TMP/clone" && git -C "$TMP/clone" push -q origin main

STUB="$TMP/stub"; mkdir -p "$STUB" "$TMP/gh" "$TMP/claude-log"
cp "$HERE/stubs/gh.js" "$STUB/gh.js"
printf '#!/usr/bin/env bash\nexec node "%s/gh.js" "$@"\n' "$STUB" > "$STUB/gh"; chmod +x "$STUB/gh"
cp "$HERE/stubs/claude.sh" "$STUB/claude"; chmod +x "$STUB/claude"
export GH_STUB_DIR="$TMP/gh" GH_STUB_REMOTE="$TMP/remote.git" CLAUDE_STUB_LOG="$TMP/claude-log" CLAUDE_STUB_TARGET="acme/api"
export GH_BIN="$STUB/gh" CLAUDE_BIN="$STUB/claude"
export CLAUDE_CONFIG_FILE="$TMP/claude.json"
node -e "require('fs').writeFileSync('$TMP/claude.json', JSON.stringify({projects:{['$TMP/clone']:{hasTrustDialogAccepted:true}}}))"
export CLAUDE_STUB_MODE_T1_3=silent

BODY=$(printf '**Part of** #1 · **Phase 1 · x** · **Repo:** `acme/api`\n\n## Goal\nx\n\n### SCOPE.json\n```json\n{"feature":"f","branch":"feat/t1-3-silent","allowedPaths":["src/**"],"forbiddenPaths":[],"dependsOn":[],"execution":{"model":"default","pattern":"solo"}}\n```\n')
node - "$TMP/gh" "$BODY" <<'JS'
const fs = require('fs'); const [dir, body] = process.argv.slice(2);
fs.writeFileSync(`${dir}/issues.json`, JSON.stringify([
  { number: 1, title: 'Epic: program T', body: '', state: 'OPEN', labels: ['epic'] },
  { number: 12, title: 'T1.3 Silent one', body, state: 'OPEN', labels: ['agent-ready', 'cell:queued', 'worker:a'] },
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
  "pluginRoot": "$PLUGIN", "maxEscalations": 2, "noMovementLimit": 5, "sessionTimeoutMinutes": 5,
  "models": { "cheapest": "haiku", "default": null, "strongest": "opus" }
}
JSON
fleet() { node "$FLEET" "$@" --config "$TMP/fleet.config.json"; }
wait_exit() { local f="$TMP/state/logs/$1.exit" i=0; until [ -f "$f" ] || [ $i -ge 60 ]; do sleep 0.5; i=$((i + 1)); done; [ -f "$f" ]; }
# Through the stub's `issue edit`, as the coordinator would: label writes land
# in labels.json, which shadows issues.json once sync has written a label.
set_ready() { "$STUB/gh" issue edit 12 "--$1-label" agent-ready >/dev/null; } # add|remove
status12() { node -e "console.log(require('$TMP/state/state.json').sessions[12].status)"; }

# --- A. launch, then the worker exits silent ---------------------------------
OUT=$(fleet cycle --apply --json 2>/dev/null)
assert_contains "$OUT" '"attempt": 1' "the package is launched at attempt 1"
wait_exit 12-1 && _pass "attempt 1 exited" || _fail "attempt 1 exited" "no exit file 12-1"

# --- B. agent-ready removed: the escalation is held ---------------------------
set_ready remove
OUT=$(fleet cycle --apply --json 2>/dev/null); EXIT=$?
assert_eq 0 "$EXIT" "the reaping cycle exits 0"
assert_contains "$OUT" '"reason": "silent"' "the silent exit is reaped"
assert_not_contains "$OUT" '"escalations": [{' "no escalation is recorded while the label is off"
assert_contains "$OUT" 'held: no agent-ready label' "the hold is reported with its reason"
assert_eq "retry" "$(status12)" "the session is kept for retry"
assert_eq "1" "$(node -e "console.log(require('$TMP/state/state.json').dispatches['T1.3'].length)")" "no new dispatch is recorded"
# Read at once: a held request returns before the spawn, so no detached stub
# exists to write here later.
assert_not_contains "$(ls "$TMP/claude-log")" "T1.3.2" "no second attempt is launched"
assert_contains "$(fleet cycle --json 2>/dev/null)" 'held: no agent-ready label' "the dry-run report names the hold"

# --- C. the hold lasts across cycles -----------------------------------------
OUT=$(fleet cycle --apply --json 2>/dev/null)
assert_contains "$OUT" 'held: no agent-ready label' "the next cycle holds it again"
assert_not_contains "$(ls "$TMP/claude-log")" "T1.3.2" "still no second attempt"
assert_eq "retry" "$(status12)" "the session is still kept for retry"

# --- D. the label is back: the held escalation goes ahead ---------------------
set_ready add
OUT=$(fleet cycle --apply --json 2>/dev/null); EXIT=$?
assert_eq 0 "$EXIT" "the cycle after the label is back exits 0"
assert_contains "$OUT" '"to": "strongest"' "the held escalation goes one tier up"
assert_not_contains "$OUT" 'held: no agent-ready label' "nothing is held"
wait_exit 12-2 && _pass "attempt 2 ran" || _fail "attempt 2 ran" "no exit file 12-2"
wait_for_file "$TMP/claude-log/T1.3.2.argv"
assert_contains "$(cat "$TMP/claude-log/T1.3.2.argv")" "opus" "attempt 2 runs at the strongest tier"

finish
