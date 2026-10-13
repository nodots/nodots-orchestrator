#!/usr/bin/env bash
# Fixture test for .github/workflows/evals.yml: the triggers, the monthly-ceiling
# step, and the pass-rate gate. The ceiling and gate steps are extracted from the
# workflow and run against fixtures, so the test runs the code CI runs.
set -uo pipefail
cd "$(dirname "$0")"
. ../../plugins/fleet/tests/lib.sh

ROOT="$(cd ../.. && pwd -P)"
WF="$ROOT/.github/workflows/evals.yml"
assert_file "$WF" "evals.yml exists"
assert_file "$ROOT/evals/baseline.json" "evals/baseline.json exists"
assert_file "$ROOT/evals/spend.json" "evals/spend.json exists"
[ -f "$WF" ] || finish

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Triggers. Match uncommented lines only: the header may mention a schedule in a comment.
live() { grep -v '^[[:space:]]*#' "$WF"; }
# Owner decision 2026-10-13: manual trigger only. The runner has no model credential, so a
# per-PR trigger failed on every PR.
assert_contains "$(live)" "workflow_dispatch:" "runs on manual dispatch"
assert_not_contains "$(live)" "pull_request:" "does not run on pull_request"
assert_not_contains "$(live)" "schedule:" "no live schedule trigger until calibration merges"
assert_not_contains "$(live)" "cron:" "no live cron entry until calibration merges"
assert_contains "$(grep '^#' "$WF")" "calibration" "header states why the schedule is off"
assert_contains "$(grep '^#' "$WF")" "#25" "header names epic #25"

# step <name>: the body of that step's `run: |` block.
step() {
  awk -v name="$1" '
    $0 ~ "^ *- name: " name "$" { on = 1; next }
    on && /^ *run: \|$/ { grab = 1; match($0, /^ */); base = RLENGTH; next }
    grab { match($0, /^ */); if ($0 != "" && RLENGTH <= base) exit; sub("^ {" base + 2 "}", ""); print }
  ' "$WF"
}
CEILING_STEP=$(step "Monthly ceiling check")
GATE_STEP=$(step "Pass-rate gate")
assert_nonempty "$CEILING_STEP" "workflow has a Monthly ceiling check step"
assert_nonempty "$GATE_STEP" "workflow has a Pass-rate gate step"
[ -n "$CEILING_STEP" ] && [ -n "$GATE_STEP" ] || finish
printf '%s\n' "$CEILING_STEP" > "$TMP/ceiling.sh"
printf '%s\n' "$GATE_STEP" > "$TMP/gate.sh"

# The ceiling step runs before the evals, and the gate after.
order=$(grep -n -E '^ *- name: (Monthly ceiling check|Run evals|Pass-rate gate)$' "$WF" | sed 's/^[0-9]*: *- name: //' | tr '\n' ',')
assert_eq "Monthly ceiling check,Run evals,Pass-rate gate," "$order" "steps run in order: ceiling, evals, gate"

# Fixtures.
printf '{"perEvalUsd":1,"perSuiteUsd":25,"monthlyCeilingUsd":200,"model":"sonnet"}\n' > "$TMP/budget.json"
mkspend() { printf '{"runs":%s}\n' "$1" > "$TMP/spend.json"; }
mkbase() { printf '{"passRate":%s}\n' "$1" > "$TMP/baseline.json"; }
# mkresults <passed> <failed> <not-run>
mkresults() {
  node -e '
    const [p, f, n] = process.argv.slice(1).map(Number); const evals = [];
    for (let i = 0; i < p; i++) evals.push({ id: "p" + i, status: "passed" });
    for (let i = 0; i < f; i++) evals.push({ id: "f" + i, status: "failed" });
    for (let i = 0; i < n; i++) evals.push({ id: "n" + i, status: "not-run" });
    process.stdout.write(JSON.stringify({ evals }));' "$1" "$2" "$3" > "$TMP/results.json"
}
export BUDGET_FILE="$TMP/budget.json" SPEND_FILE="$TMP/spend.json" BASELINE_FILE="$TMP/baseline.json" RESULTS_FILE="$TMP/results.json"
export GITHUB_OUTPUT="$TMP/out" NOW_MONTH="2026-10"
runstep() { OUT=$(bash "$TMP/$1.sh" 2>&1); RC=$?; }

# Ceiling: spend below the ceiling continues and is passed on; other months do not count.
mkspend '[{"date":"2026-10-03","usd":120.5},{"date":"2026-09-30","usd":900},{"date":"2026-10-09","usd":30}]'
: > "$TMP/out"
runstep ceiling
assert_eq "0" "$RC" "month-to-date below ceiling: exit 0"
assert_contains "$(cat "$TMP/out")" "month_spent=150.5" "only this month's runs are summed"

# Ceiling: spend equal to the ceiling stops the run and fails loudly.
mkspend '[{"date":"2026-10-03","usd":150},{"date":"2026-10-09","usd":50}]'
runstep ceiling
assert_eq "1" "$RC" "month-to-date meets the ceiling: exit 1"
assert_contains "$OUT" "MONTHLY CEILING REACHED" "the stop is loud"
assert_contains "$OUT" "200" "the message shows the ceiling"

# Ceiling: spend above the ceiling fails too.
mkspend '[{"date":"2026-10-03","usd":250}]'
runstep ceiling
assert_eq "1" "$RC" "month-to-date above the ceiling: exit 1"

# Ceiling: an unreadable ledger fails closed, never reads as zero spend.
printf 'not json' > "$TMP/spend.json"
runstep ceiling
assert_eq "1" "$RC" "unreadable spend ledger: exit 1"
mkspend '[{"date":"2026-10-03","usd":"lots"}]'
runstep ceiling
assert_eq "1" "$RC" "a non-numeric spend entry: exit 1"

# Gate: pass rate below baseline fails.
mkbase 0.9
mkresults 17 3 0
runstep gate
assert_eq "1" "$RC" "pass rate 0.85 below baseline 0.9: exit 1"
assert_contains "$OUT" "below baseline" "the drop is named"

# Gate: at or above baseline passes.
mkresults 18 2 0
runstep gate
assert_eq "0" "$RC" "pass rate equal to baseline: exit 0"
mkresults 20 0 0
runstep gate
assert_eq "0" "$RC" "pass rate above baseline: exit 0"

# Gate: evals that did not run count as not passed.
mkresults 17 0 3
runstep gate
assert_eq "1" "$RC" "not-run evals lower the pass rate: exit 1"

# Gate: no recorded baseline means 100% is required; the output says so.
mkbase null
mkresults 19 1 0
runstep gate
assert_eq "1" "$RC" "no baseline and one failure: exit 1"
assert_contains "$OUT" "no baseline recorded" "unrecorded baseline is stated"
mkresults 20 0 0
runstep gate
assert_eq "0" "$RC" "no baseline and all passed: exit 0"

# Gate: an empty or missing results file fails closed.
printf '{"evals":[]}' > "$TMP/results.json"
runstep gate
assert_eq "1" "$RC" "zero evals: exit 1"
rm -f "$TMP/results.json"
runstep gate
assert_eq "1" "$RC" "no results file: exit 1"

# The committed files are well-formed and carry no secret value.
assert_eq "true" "$(node -p "const b=require('$ROOT/evals/baseline.json'); b.passRate===null || (typeof b.passRate==='number' && b.passRate>=0 && b.passRate<=1)")" "committed baseline.json passRate is null or in [0,1]"
assert_eq "true" "$(node -p "Array.isArray(require('$ROOT/evals/spend.json').runs)")" "committed spend.json has a runs array"
assert_contains "$(live)" '${{ secrets.ANTHROPIC_API_KEY }}' "the API key comes from a secret reference"
assert_eq "0" "$(grep -c -E 'sk-ant-[A-Za-z0-9_-]{10,}' "$WF")" "no key literal in the workflow"

finish
