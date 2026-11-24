#!/usr/bin/env bash
# Label provenance in fleet doctor (X0.4). With `coordinators` set, doctor
# checks that fleet's own gh login is one, then reads the timeline of every
# open issue in the host repo carrying agent-ready, cell:* or worker:* (not
# only the epic's) and prints one FAIL line per label applied by an account
# that is not a coordinator, suffixed "(outside epic #<n>)" for an issue that
# is not part of the epic. All from coordinators is one ok line. A timeline
# that cannot be read is a FAIL naming the issue. Without `coordinators`,
# doctor prints a WARN and reads no timeline.
#
# Fixture: host repo acme/host, epic #1; #10 is in the epic, #20 names epic
# #99, #30 is closed and carries a foreign label doctor must not judge. The gh
# stub's timeline.json records who applied each label.
set -uo pipefail
cd "$(dirname "$0")"
. ./lib.sh

HERE=$(pwd -P)
FLEET="$(cd .. && pwd -P)/bin/fleet.js"
PLUGIN="$(cd ../../agentic-work-packages && pwd -P)"
assert_file "$FLEET" "fleet.js exists"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
TMP=$(cd "$TMP" && pwd -P)

git init -q --bare -b main "$TMP/remote.git"
git clone -q "$TMP/remote.git" "$TMP/clone" 2>/dev/null
git -C "$TMP/clone" checkout -q -b main 2>/dev/null || true
git -C "$TMP/clone" config user.email f@example.invalid; git -C "$TMP/clone" config user.name fixture
printf '# api\n' > "$TMP/clone/README.md"
git -C "$TMP/clone" add -A && git -C "$TMP/clone" commit -qm init
fixture_standards "$TMP/clone"
# Doctor's other checks pass, so its exit code moves only with provenance.
printf '{"hooks": {"PreToolUse": [{"hooks": [{"command": "enforce-scope.js"}]}], "Stop": [{"hooks": [{"command": "require-handoff.js"}]}]}}\n' > "$TMP/clone/.claude/settings.json"
printf '# contract\n' > "$TMP/clone/.claude/worker-contract.md"
git -C "$TMP/clone" add -A && git -C "$TMP/clone" commit -qm "fixture: hooks and contract" && git -C "$TMP/clone" push -q -u origin main

STUB="$TMP/stub"; mkdir -p "$STUB" "$TMP/gh" "$TMP/claude-log"
cp "$HERE/stubs/gh.js" "$STUB/gh.js"
printf '#!/usr/bin/env bash\nexec node "%s/gh.js" "$@"\n' "$STUB" > "$STUB/gh"; chmod +x "$STUB/gh"
cp "$HERE/stubs/claude.sh" "$STUB/claude"; chmod +x "$STUB/claude"
export GH_STUB_DIR="$TMP/gh" GH_STUB_REMOTE="$TMP/remote.git" CLAUDE_STUB_LOG="$TMP/claude-log" CLAUDE_STUB_TARGET="acme/api"
export GH_BIN="$STUB/gh" CLAUDE_BIN="$STUB/claude"
export CLAUDE_CONFIG_FILE="$TMP/claude.json"
node -e "require('fs').writeFileSync('$TMP/claude.json', JSON.stringify({projects:{['$TMP/clone']:{hasTrustDialogAccepted:true}}}))"
unset CLAUDECODE FLEET_STUB_LOGIN

node - "$TMP/gh" <<'JS'
const fs = require('fs'); const [dir] = process.argv.slice(2);
const body = epic => `**Part of** #${epic} · **Phase 1 · x** · **Repo:** \`acme/api\`\n\n## Goal\nx\n`;
fs.writeFileSync(`${dir}/issues.json`, JSON.stringify([
  { number: 1, title: 'Epic: program T', body: '', state: 'OPEN', labels: ['epic'] },
  { number: 10, title: 'T1.1 Web', body: body(1), state: 'OPEN', labels: ['agent-ready', 'cell:queued', 'worker:a'] },
  { number: 20, title: 'T9.1 Other', body: body(99), state: 'OPEN', labels: ['agent-ready'] },
  { number: 30, title: 'T1.2 Done', body: body(1), state: 'CLOSED', labels: ['worker:a'] },
], null, 2));
fs.writeFileSync(`${dir}/prs.json`, '[]'); fs.writeFileSync(`${dir}/labels.json`, '{}');
fs.writeFileSync(`${dir}/comments.json`, '{}'); fs.writeFileSync(`${dir}/writes.log`, '');
JS
printf '{}' > "$TMP/gh/ci.json"

# timeline <json>: replace the stub's timeline.json and clear the read log.
timeline() { printf '%s\n' "$1" > "$TMP/gh/timeline.json"; : > "$TMP/gh/reads.log"; }
ev() { printf '{"event":"labeled","label":{"name":"%s"},"actor":{"login":"%s"}}' "$1" "$2"; }
ALL_COORD="{\"10\": [$(ev agent-ready coordinator), $(ev cell:queued coordinator), $(ev worker:a coordinator)], \"20\": [$(ev agent-ready coordinator)], \"30\": [$(ev worker:a jack)]}"

# config <coordinators JSON or empty>: write fleet.config.json.
config() {
  local coord=""; [ -n "$1" ] && coord="\"coordinators\": $1,"
  cat > "$TMP/fleet.config.json" <<JSON
{
  "repo": "acme/host", "epic": 1, $coord
  "targets": [{ "repo": "acme/api", "localPath": "$TMP/clone", "defaultBranch": "main" }],
  "workers": { "a": { "mode": "local" } },
  "wipCap": 4, "worktreesDir": "$TMP/worktrees", "stateDir": "$TMP/state",
  "pluginRoot": "$PLUGIN", "noMovementLimit": 99
}
JSON
}
fleet() { node "$FLEET" "$@" --config "$TMP/fleet.config.json"; }
prov() { printf '%s\n' "$1" | grep -E "provenance|coordinator|^(FAIL|ok   ) +label (agent-ready|cell:|worker:).* on #"; }

# --- A. every label from a coordinator: the ok line --------------------------------
config '["coordinator", "ken"]'
timeline "$ALL_COORD"
OUT=$(fleet doctor 2>/dev/null); OK_EXIT=$?
assert_contains "$OUT" "ok    label provenance: 2 issues, all from coordinators" "A: all from coordinators prints the ok line"
assert_empty "$(prov "$OUT" | grep '^FAIL')" "A: no provenance FAIL line"
assert_empty "$(printf '%s\n' "$OUT" | grep '^FAIL')" "A: no FAIL line at all"
assert_eq "0" "$OK_EXIT" "A: doctor exits 0"
assert_contains "$(cat "$TMP/gh/reads.log")" "timeline acme/host 10" "A: #10's timeline is read"
assert_contains "$(cat "$TMP/gh/reads.log")" "timeline acme/host 20" "A: #20 (outside the epic) is read too"
assert_not_contains "$(cat "$TMP/gh/reads.log")" "timeline acme/host 30" "A: a closed issue is not read"
assert_empty "$(grep -x 'timeline acme/host 1' "$TMP/gh/reads.log")" "A: the epic, with no judged label, is not read"

# --- B. worker:a on #10 labeled by jack: FAIL naming label, issue and jack ---------
timeline "{\"10\": [$(ev agent-ready coordinator), $(ev cell:queued coordinator), $(ev worker:a jack)], \"20\": [$(ev agent-ready coordinator)]}"
OUT=$(fleet doctor 2>/dev/null); JACK_EXIT=$?
L=$(printf '%s\n' "$OUT" | grep '^FAIL  label worker:a on #10')
assert_eq "FAIL  label worker:a on #10 T1.1: applied by jack, not a coordinator" "$L" "B: the FAIL line names the label, issue and jack"
assert_eq "1" "$(prov "$OUT" | grep -c '^FAIL')" "B: one provenance FAIL line"
assert_not_contains "$OUT" "label provenance: 2 issues, all from coordinators" "B: no ok line"
assert_ne "0" "$JACK_EXIT" "B: doctor exits non-zero"
# The fixture's other checks are the same as in A, so the flagged label is the only new FAIL.
timeline "$ALL_COORD"; A_FAILS=$(fleet doctor 2>/dev/null | grep -c '^FAIL')
assert_eq "$((A_FAILS + 1))" "$(printf '%s\n' "$OUT" | grep -c '^FAIL')" "B: exactly one more FAIL than with every label from a coordinator"

# --- C. a flagged issue outside the epic carries the suffix ------------------------
timeline "{\"10\": [$(ev agent-ready coordinator), $(ev cell:queued coordinator), $(ev worker:a coordinator)], \"20\": [$(ev agent-ready jack)]}"
OUT=$(fleet doctor 2>/dev/null)
assert_eq "FAIL  label agent-ready on #20 T9.1: applied by jack, not a coordinator (outside epic #1)" "$(printf '%s\n' "$OUT" | grep '^FAIL  label agent-ready on #20')" "C: the outside-epic issue is listed with (outside epic #1)"
assert_not_contains "$(prov "$OUT")" "on #10" "C: the epic's clean issue draws no line"

# --- C2. a label with no labeled event, and a timeline that cannot be read --------
timeline "{\"10\": [$(ev agent-ready coordinator), $(ev cell:queued coordinator)], \"20\": \"fail\"}"
OUT=$(fleet doctor 2>/dev/null)
assert_eq "FAIL  label worker:a on #10 T1.1: applied by an unknown account (no labeled event by a known login), not a coordinator" "$(printf '%s\n' "$OUT" | grep '^FAIL  label worker:a on #10')" "C2: a label with no labeled event is flagged"
L=$(printf '%s\n' "$OUT" | grep '^FAIL  label provenance on #20')
assert_contains "$L" "T9.1" "C2: a failed timeline read is a FAIL naming the issue"
assert_contains "$L" "502" "C2: and the error"
assert_contains "$L" "(outside epic #1)" "C2: and that it is outside the epic"

# --- D. fleet's login is not in coordinators ---------------------------------------
timeline "$ALL_COORD"
OUT=$(FLEET_STUB_LOGIN=mallory fleet doctor 2>/dev/null)
assert_contains "$OUT" "FAIL  fleet's gh login mallory is not in coordinators" "D: the login FAIL line names the login"
OUT=$(fleet doctor 2>/dev/null)
assert_not_contains "$OUT" "is not in coordinators" "D: a coordinator login draws no login FAIL"

# --- E. no coordinators: the WARN line, and no timeline is read --------------------
config ''
timeline "{\"10\": [$(ev worker:a jack)]}"
OUT=$(fleet doctor 2>/dev/null)
assert_contains "$OUT" "WARN  coordinators: not set; fleet trusts agent-ready, cell:* and worker:* from any account" "E: the WARN line"
assert_not_contains "$(cat "$TMP/gh/reads.log" 2>/dev/null)" "timeline" "E: no timeline is read"
assert_empty "$(prov "$OUT" | grep '^FAIL')" "E: no provenance FAIL line"
config '[]'
assert_contains "$(fleet doctor 2>/dev/null)" "WARN  coordinators: not set" "E: coordinators [] is not set too"

# --- F. doctor's header lists the check --------------------------------------------
assert_contains "$(sed -n 12p "$FLEET")" "label provenance" "F: the header line lists label provenance"

finish
