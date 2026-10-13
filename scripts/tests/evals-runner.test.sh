#!/usr/bin/env bash
# Fixture test for evals/run.js: caps are enforced, an unrun eval is never a
# pass, and a cost the runner cannot read prints as unknown, never zero.
# claude is the stub in evals/tests/stubs/claude.sh; no real model is called.
set -uo pipefail
cd "$(dirname "$0")"
. ../../plugins/fleet/tests/lib.sh

ROOT="$(cd ../.. && pwd -P)"
RUN="$ROOT/evals/run.js"
STUB="$ROOT/evals/tests/stubs/claude.sh"
assert_file "$RUN" "evals/run.js exists"
assert_file "$STUB" "the claude stub exists"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export EVAL_STUB_LOG="$TMP/log"
mkdir -p "$TMP/work"

# mkcase <dir> <id> <prompt> [checks-json]
mkcase() {
  mkdir -p "$1"
  printf '{"id":"%s","prompt":"%s","checks":%s}\n' "$2" "$3" "${4:-[]}" > "$1/$2.json"
}
# mkbudget <file> <per-eval> <per-suite> <monthly>
mkbudget() {
  printf '{"perEvalUsd":%s,"perSuiteUsd":%s,"monthlyCeilingUsd":%s,"model":"sonnet"}\n' "$2" "$3" "$4" > "$1"
}
run() { OUT=$(node "$RUN" --claude "bash $STUB" --workdir "$TMP/work" "$@" 2>&1); RC=$?; }

# 1. Every eval inside its cap passes; measured cost is shown per eval and per suite.
mkcase "$TMP/c1" a "stub:cost=0.30 stub:write=a.txt" '[{"name":"file made","kind":"tests","command":"test -f a.txt"}]'
mkcase "$TMP/c1" b "stub:cost=0.20"
mkbudget "$TMP/b1.json" 1 5 50
run --cases "$TMP/c1" --budget "$TMP/b1.json" --results "$TMP/r1.json"
assert_eq "0" "$RC" "all evals inside their caps: exit 0"
assert_contains "$OUT" "PASS a" "eval a passes"
assert_contains "$OUT" '$0.3000 [measured]' "eval a cost is measured"
assert_contains "$OUT" 'suite spent: $0.5000 [measured]' "suite cost is the measured sum"
assert_contains "$OUT" "monthly spend: unknown" "monthly spend not supplied is unknown"
assert_file "$TMP/r1.json" "machine-readable results are written"
assert_eq "passed" "$(node -p "require('$TMP/r1.json').evals[0].status")" "results file records status"
assert_eq "0.3" "$(node -p "require('$TMP/r1.json').evals[0].costUsd")" "results file records measured cost"

# 2. A failing check fails the eval and the run.
mkcase "$TMP/c2" f "stub:cost=0.10" '[{"name":"no such file","kind":"tests","command":"test -f never.txt"}]'
run --cases "$TMP/c2" --budget "$TMP/b1.json"
assert_eq "1" "$RC" "a failed check: exit 1"
assert_contains "$OUT" "FAIL f" "the eval is reported failed"
assert_contains "$OUT" "no such file" "the failing check is named"

# 3. Per-eval cap exceeded: non-zero, spent versus cap printed.
mkcase "$TMP/c3" big "stub:cost=1.50"
run --cases "$TMP/c3" --budget "$TMP/b1.json"
assert_eq "1" "$RC" "per-eval cap exceeded: exit 1"
assert_contains "$OUT" "FAIL big" "the over-cap eval is failed"
assert_contains "$OUT" 'per-eval cap exceeded: spent $1.5000, cap $1.0000' "spent and cap are printed"

# 4. The budget flag handed to claude is the per-eval cap, bounded by what the suite has left.
run --cases "$TMP/c1" --budget "$TMP/b1.json"
assert_contains "$(cat "$TMP/log/argv.1")" "--max-budget-usd" "claude gets --max-budget-usd"
assert_contains "$(cat "$TMP/log/argv.1")" "1" "the first eval gets the per-eval cap"
mkbudget "$TMP/b4.json" 1 1.2 50
rm -rf "$TMP/log"
run --cases "$TMP/c1" --budget "$TMP/b4.json"
assert_contains "$(tr '\n' ' ' < "$TMP/log/argv.2")" "--max-budget-usd 0.9" "the second eval gets the suite remainder (1.2 - 0.3)"

# 5. Per-suite cap reached: non-zero, unrun evals listed, none reported as a pass.
mkcase "$TMP/c5" e1 "stub:cost=0.60"
mkcase "$TMP/c5" e2 "stub:cost=0.60"
mkcase "$TMP/c5" e3 "stub:cost=0.60"
mkcase "$TMP/c5" e4 "stub:cost=0.60"
mkbudget "$TMP/b5.json" 1 1.2 50
rm -rf "$TMP/log"
run --cases "$TMP/c5" --budget "$TMP/b5.json" --results "$TMP/r5.json"
assert_eq "1" "$RC" "suite cap reached: exit 1"
assert_contains "$OUT" 'SUITE CAP REACHED: spent $1.2000, cap $1.2000' "spent and cap are printed"
assert_contains "$OUT" "not run: e3, e4" "the unrun evals are listed"
assert_contains "$OUT" "NOT-RUN e3" "an unrun eval is marked not run"
assert_not_contains "$OUT" "PASS e3" "an unrun eval is never a pass"
assert_not_contains "$OUT" "PASS e4" "a second unrun eval is never a pass"
assert_eq "not-run" "$(node -p "require('$TMP/r5.json').evals[2].status")" "results file marks e3 not-run"
assert_eq "2" "$(ls "$TMP/log" | grep -c '^argv')" "claude was invoked twice, not four times"

# 6. A cost claude does not report is unknown, never zero.
mkcase "$TMP/c6" nocost "stub:nocost"
run --cases "$TMP/c6" --budget "$TMP/b1.json" --results "$TMP/r6.json"
assert_contains "$OUT" "cost unknown [unknown]" "an unreadable cost prints as unknown"
assert_not_contains "$OUT" '$0.0000' "an unreadable cost never prints as zero"
assert_eq "null" "$(node -p "JSON.stringify(require('$TMP/r6.json').evals[0].costUsd)")" "results file holds null, not 0"
assert_contains "$OUT" "suite spent: unknown" "a suite with only unreadable costs is unknown, not zero"

# 7. An unreadable cost is budgeted at the per-eval cap, so it cannot hide spend.
mkcase "$TMP/c7" u1 "stub:nocost"
mkcase "$TMP/c7" u2 "stub:nocost"
mkcase "$TMP/c7" u3 "stub:nocost"
mkbudget "$TMP/b7.json" 1 2 50
run --cases "$TMP/c7" --budget "$TMP/b7.json"
assert_eq "1" "$RC" "unknown costs reach the suite cap at their worst case: exit 1"
assert_contains "$OUT" "not run: u3" "the eval after the worst-case cap is not run"
assert_contains "$OUT" "worst case" "the output says the bound is a worst case, not a measurement"

# 8. Monthly ceiling: spend supplied by the caller caps the suite.
mkbudget "$TMP/b8.json" 1 5 1
run --cases "$TMP/c1" --budget "$TMP/b8.json" --month-spent 0.9
assert_eq "1" "$RC" "monthly ceiling reached mid-suite: exit 1"
assert_contains "$OUT" 'monthly ceiling' "the monthly ceiling is named"
assert_contains "$OUT" "not run:" "evals past the monthly ceiling are listed as not run"
run --cases "$TMP/c1" --budget "$TMP/b8.json" --month-spent 1
assert_eq "1" "$RC" "monthly ceiling already reached: exit 1"
assert_contains "$OUT" "not run: a, b" "no eval runs once the ceiling is reached"
assert_not_contains "$OUT" "PASS" "nothing passes when nothing ran"

# 9. Bad inputs fail closed.
mkdir -p "$TMP/empty"
run --cases "$TMP/empty" --budget "$TMP/b1.json"
assert_eq "2" "$RC" "a cases directory with no cases fails (the glob matches nothing)"
run --cases "$TMP/c1" --budget "$TMP/missing.json"
assert_eq "2" "$RC" "a missing budget file fails"
printf '{"perEvalUsd":"free"}\n' > "$TMP/bad.json"
run --cases "$TMP/c1" --budget "$TMP/bad.json"
assert_eq "2" "$RC" "a budget with a non-numeric cap fails"
mkdir -p "$TMP/c9"
printf '{"id":"x"}\n' > "$TMP/c9/x.json"
run --cases "$TMP/c9" --budget "$TMP/b1.json"
assert_eq "2" "$RC" "a case without a prompt fails"

# 10. claude exits non-zero: the eval fails, and its reported cost is still counted.
mkcase "$TMP/c10" crash "stub:exit3 stub:cost=0.25"
run --cases "$TMP/c10" --budget "$TMP/b1.json"
assert_eq "1" "$RC" "claude exiting non-zero fails the run"
assert_contains "$OUT" "FAIL crash" "the eval is failed"

# 11. The shipped example case and budget are well-formed.
node -e '
  const b=require(process.argv[1]+"/evals/budget.json");
  for (const k of ["perEvalUsd","perSuiteUsd","monthlyCeilingUsd"]) if(!(Number.isFinite(b[k])&&b[k]>0)) process.exit(1);
  const c=require(process.argv[1]+"/evals/cases/_example.json");
  if(!c.id||!c.prompt||!Array.isArray(c.checks)) process.exit(1);' "$ROOT"
assert_eq "0" "$?" "evals/budget.json and evals/cases/_example.json are well-formed"

finish
