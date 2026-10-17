#!/usr/bin/env bash
# V3 gate: the report is sourced. Every metric scripts/metrics.js reports has a
# label and a cited source, or is unknown; no metric is zero without a
# measurement behind it.
#
# The cited source of each metric is the SOURCES table in the checker below,
# with the metrics.js lines that read it. The checker fails a report that holds
# a metric with no entry there, so a new metric cannot ship unsourced. Tracing
# is then shown by moving the source in the stub data and watching the metric
# move with it, and by removing the source and watching it turn unknown.
#
# gh is the fleet stub (plugins/fleet/tests/stubs/gh.js). It returns no issue
# createdAt, so hours open to merge is traced through the module's compute().
#
# Real run (not part of scripts/test.sh, needs gh access):
#   bash scripts/tests/v3-gate.test.sh --repo <owner/name> [--state-dir <dir>]
# applies the same checker to `metrics.js --last 10` against the real tracker
# and prints each metric with its cited source.
set -uo pipefail
REAL_REPO='' REAL_STATE=''
usage() { echo "usage: v3-gate.test.sh [--repo <owner/name> [--state-dir <dir>]]" >&2; exit 2; }
while [ $# -gt 0 ]; do
  [ $# -ge 2 ] && [ -n "$2" ] || usage
  case "$1" in
    --repo) REAL_REPO=$2 ;;
    --state-dir) REAL_STATE=$(cd "$2" && pwd -P) || exit 2 ;;
    *) usage ;;
  esac
  shift 2
done
cd "$(dirname "$0")"
. ../../plugins/fleet/tests/lib.sh

METRICS="$(cd .. && pwd -P)/metrics.js"
GH="$(cd ../../plugins/fleet/tests/stubs && pwd -P)/gh.js"
assert_file "$METRICS" "scripts/metrics.js exists"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# check.js <report.json> — prints "ok", or one violation per line. With --cite,
# also prints each metric with its cited source.
cat > "$TMP/check.js" <<'EOF'
const fs = require('fs');
const SOURCES = {
  firstPassMergeRate: 'gh pr list: state, body "Closes #N", createdAt (metrics.js:83-105)',
  prsPerPackage: 'gh pr list: body "Closes #N", state (metrics.js:83-108)',
  stampCurrency: 'gh pr list: title, headRefOid, comments (metrics.js:110-122)',
  hoursOpenToMerge: 'gh issue view: createdAt; gh pr list: mergedAt (metrics.js:124-136, 228)',
  costPerMergedPackage: 'fleet logs <state-dir>/logs/<issue>-<attempt>.log: total_cost_usd (metrics.js:45-74, 138-149)',
  costTotal: 'fleet logs <state-dir>/logs/<issue>-<attempt>.log: total_cost_usd (metrics.js:45-74, 138-149)',
};
const PACKAGE_COST = SOURCES.costTotal;
const LABELS = ['measured', 'estimated', 'unknown'];
const r = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const bad = [];
// zeroOk: a zero value is allowed only with a count of at least one behind it.
function judge(name, m, zeroOk) {
  if (!m || !LABELS.includes(m.label)) return bad.push(`${name}: label is ${m && m.label}, not measured, estimated or unknown`);
  if (m.label === 'unknown') {
    if (m.value !== null) bad.push(`${name}: unknown but carries value ${m.value}`);
    if (!m.note) bad.push(`${name}: unknown without a note saying why`);
    if (m.display !== 'unknown') bad.push(`${name}: unknown but displays ${m.display}`);
    return;
  }
  if (!Number.isFinite(m.value)) bad.push(`${name}: ${m.label} but value is ${m.value}`);
  if (!m.display) bad.push(`${name}: ${m.label} with no display`);
  if (m.value === 0 && !zeroOk(m)) bad.push(`${name}: zero without a measurement behind it (${m.display})`);
}
const counted = m => /\bof [1-9]\d*\b/.test(m.display || '');
for (const k of Object.keys(SOURCES)) if (!(k in (r.metrics || {}))) bad.push(`${k}: missing from the report`);
for (const [k, m] of Object.entries(r.metrics || {})) {
  if (!SOURCES[k]) bad.push(`${k}: no cited source`);
  judge(k, m, counted);
}
// A package cost of zero is a log line that recorded 0, so measured or estimated suffices.
for (const p of r.packages || []) judge(`package ${p.issue} cost`, p.cost, m => m.label !== 'unknown');
if (bad.length) { process.stdout.write(bad.join('\n') + '\n'); process.exit(0); }
process.stdout.write('ok\n');
if (process.argv[3] === '--cite') {
  for (const [k, m] of Object.entries(r.metrics)) {
    process.stdout.write(`${k}: ${m.display} [${m.label}]${m.label === 'unknown' ? ` -- ${m.note}` : ''}\n  source: ${SOURCES[k]}\n`);
  }
  for (const p of r.packages || []) if (p.cost.label !== 'unknown') process.stdout.write(`package ${p.issue} cost: ${p.cost.display} [${p.cost.label}]\n  source: ${PACKAGE_COST}\n`);
}
EOF

# --- real run (opt-in) ---------------------------------------------------------

if [ -n "$REAL_REPO" ]; then
  REAL=(--repo "$REAL_REPO" --last 10 --json)
  [ -n "$REAL_STATE" ] && REAL+=(--state-dir "$REAL_STATE")
  node "$METRICS" "${REAL[@]}" > "$TMP/real.json"
  assert_eq "0" "$?" "real run: metrics.js --last 10 exits 0 on $REAL_REPO"
  CITED=$(node "$TMP/check.js" "$TMP/real.json" --cite)
  printf '%s\n' "$CITED" | sed 's/^/        /'
  assert_eq "ok" "$(printf '%s\n' "$CITED" | head -n 1)" "real run: every metric has a label and a cited source, or is unknown"
fi

# --- stub data -----------------------------------------------------------------

mkdir -p "$TMP/gh" "$TMP/state/logs"
export GH_STUB_DIR="$TMP/gh" GH_BIN="$GH"

S1=1111111111111111111111111111111111111111
S3=3333333333333333333333333333333333333333
S4=4444444444444444444444444444444444444444
OLD=9999999999999999999999999999999999999999

cat > "$TMP/gh/issues.json" <<EOF
[{"number":201,"title":"P1","body":"","labels":[],"state":"CLOSED"},
 {"number":202,"title":"P2","body":"","labels":[],"state":"CLOSED"},
 {"number":203,"title":"P3","body":"","labels":[],"state":"CLOSED"}]
EOF

# prs <pr12-state> <pr14-comments> [extra-pr-json]
# 201: PR 11, current stamp. 202: PR 12 (state given), then PR 13 merged with a
# stale stamp. 203: PR 14 merged, comments given.
prs() {
  local merged12=''
  [ "$1" = MERGED ] && merged12=',"mergedAt":"2026-10-03T12:00:00Z"'
  cat > "$TMP/gh/prs.json" <<EOF
[{"number":11,"title":"[READY]: P1","body":"Closes #201","state":"MERGED","headRefOid":"$S1","createdAt":"2026-10-01T00:00:00Z","mergedAt":"2026-10-02T00:00:00Z","comments":[{"body":"VERIFIED: unit @ $S1"}]},
 {"number":12,"title":"[READY]: P2 first","body":"Closes #202","state":"$1","headRefOid":"$OLD","createdAt":"2026-10-03T00:00:00Z"$merged12,"comments":[]},
 {"number":13,"title":"[READY]: P2 second","body":"Closes #202","state":"MERGED","headRefOid":"$S3","createdAt":"2026-10-04T00:00:00Z","mergedAt":"2026-10-05T00:00:00Z","comments":[{"body":"VERIFIED: unit @ $OLD"}]},
 {"number":14,"title":"[READY]: P3","body":"Closes #203","state":"MERGED","headRefOid":"$S4","createdAt":"2026-10-06T00:00:00Z","mergedAt":"2026-10-07T00:00:00Z","comments":$2}${3:+,$3}]
EOF
}

# report <label> [metrics.js args] — text in OUT, JSON checked by check.js.
report() {
  local label=$1; shift
  OUT=$(node "$METRICS" --repo acme/api --last 10 "$@" 2>&1); RC=$?
  assert_eq "0" "$RC" "$label: the collector exits 0"
  node "$METRICS" --repo acme/api --last 10 --json "$@" > "$TMP/r.json" 2>&1
  assert_eq "ok" "$(node "$TMP/check.js" "$TMP/r.json")" "$label: every metric has a label and a cited source, or is unknown"
  local bare
  bare=$(printf '%s\n' "$OUT" | grep -v '^#' | grep -v -E '\[(measured|estimated|unknown)\]$' | wc -l | tr -d ' ')
  assert_eq "0" "$bare" "$label: every printed value carries its label"
}

# Base fixture.
prs CLOSED '[]'
report "base"
assert_contains "$OUT" "first-pass merge rate: 66.7% (2 of 3 packages) [measured]" "base: first-pass merge rate"
assert_contains "$OUT" "PRs per package: 1.33 (4 PRs, 3 packages) [measured]" "base: PRs per package"
assert_contains "$OUT" "stamp currency: 25.0% (1 of 4 READY PRs) [measured]" "base: stamp currency"
assert_contains "$OUT" "hours open to merge: unknown [unknown]" "base: no issue createdAt from gh, so hours are unknown"
assert_contains "$OUT" "# cost total: no --state-dir given, so no fleet log was read" "base: unknown cost says why"
assert_not_contains "$OUT" '$0' "base: unknown cost is not printed as zero"

# Trace: each metric moves when its source moves.
prs MERGED '[]'
report "first attempt of 202 merged"
assert_contains "$OUT" "first-pass merge rate: 100.0% (3 of 3 packages) [measured]" "first-pass merge rate follows PR state"

prs CLOSED '[]' "{\"number\":15,\"title\":\"P3 retry\",\"body\":\"Closes #203\",\"state\":\"CLOSED\",\"headRefOid\":\"$S4\",\"createdAt\":\"2026-10-06T06:00:00Z\",\"comments\":[]}"
report "a second PR for 203"
assert_contains "$OUT" "PRs per package: 1.67 (5 PRs, 3 packages) [measured]" "PRs per package follows the PR list"

prs CLOSED "[{\"body\":\"VERIFIED: unit @ $S4\"}]"
report "203 stamped at its head"
assert_contains "$OUT" "stamp currency: 50.0% (2 of 4 READY PRs) [measured]" "stamp currency follows the VERIFIED comments"

# Zero with a measurement behind it: READY PRs exist, none is stamped at its head.
prs CLOSED '[]'
sed -e "s/VERIFIED: unit @ $S1/VERIFIED: unit @ $OLD/" "$TMP/gh/prs.json" > "$TMP/gh/prs.tmp" && mv "$TMP/gh/prs.tmp" "$TMP/gh/prs.json"
report "no current stamp"
assert_contains "$OUT" "stamp currency: 0.0% (0 of 4 READY PRs) [measured]" "a zero stamp currency names the READY PRs it measured"

# No READY PR: the source is absent, so unknown, not 0%.
prs CLOSED '[]'
sed -e 's/\[READY\]: //' "$TMP/gh/prs.json" > "$TMP/gh/prs.tmp" && mv "$TMP/gh/prs.tmp" "$TMP/gh/prs.json"
report "no READY PR"
assert_contains "$OUT" "stamp currency: unknown [unknown]" "no READY PR: stamp currency is unknown"
assert_contains "$OUT" "# stamp currency: no READY PR in the window" "no READY PR: the note says why"
assert_not_contains "$OUT" "stamp currency: 0" "no READY PR: stamp currency is not zero"

# No merged package: every metric is unknown, none is zero.
printf '[{"number":21,"title":"open","body":"Closes #201","state":"OPEN","headRefOid":"%s","createdAt":"2026-10-01T00:00:00Z","comments":[]}]\n' "$S1" > "$TMP/gh/prs.json"
report "no merged package"
UNK=$(printf '%s\n' "$OUT" | grep -v '^#' | grep -c -E ': unknown \[unknown\]$')
assert_eq "6" "$UNK" "no merged package: all six metrics are unknown"
assert_not_contains "$(printf '%s\n' "$OUT" | grep -v '^#')" "0" "no merged package: no metric line holds a zero"

# Cost: from fleet logs, moves with the log, unknown without one.
prs CLOSED '[]'
printf '{"type":"result","total_cost_usd":0.4}\n' > "$TMP/state/logs/201-1.log"
printf '{"type":"result","total_cost_usd":0.2}\n' > "$TMP/state/logs/202-1.log"
printf '{"type":"result","total_cost_usd":0.3}\n' > "$TMP/state/logs/203-1.log"
report "every package logged" --state-dir "$TMP/state"
assert_contains "$OUT" "cost total: \$0.90 (3 of 3 packages have log cost) [measured]" "cost total is the sum of the logged costs"
assert_contains "$OUT" "cost per merged package: \$0.30 (mean of 3 packages with log cost) [measured]" "cost per package is their mean"

printf '{"type":"result","total_cost_usd":1.3}\n' > "$TMP/state/logs/203-1.log"
report "203 log changed" --state-dir "$TMP/state"
assert_contains "$OUT" "cost total: \$1.90 (3 of 3 packages have log cost) [measured]" "cost total follows the log"

printf 'killed before it printed a result\n' > "$TMP/state/logs/203-1.log"
report "203 log has no result" --state-dir "$TMP/state"
assert_contains "$OUT" "package 203 cost: unknown [unknown]" "a log without a result is unknown"
assert_contains "$OUT" "cost total: \$0.60 (2 of 3 packages have log cost) [estimated]" "a total with a gap is estimated"

# A log that recorded 0 is a measured zero, and the totals say what they counted.
printf '{"type":"result","total_cost_usd":0}\n' > "$TMP/state/logs/201-1.log"
printf '{"type":"result","total_cost_usd":0}\n' > "$TMP/state/logs/202-1.log"
report "logs that recorded zero" --state-dir "$TMP/state"
assert_contains "$OUT" "package 201 cost: \$0.00 [measured]" "a recorded zero cost is measured"
assert_contains "$OUT" "cost total: \$0.00 (2 of 3 packages have log cost) [estimated]" "a zero total names the packages it counted"

rm -f "$TMP"/state/logs/*.log
report "no fleet logs" --state-dir "$TMP/state"
assert_contains "$OUT" "cost total: unknown [unknown]" "no fleet log: cost total is unknown"
assert_not_contains "$OUT" '$0' "no fleet log: no cost is printed as zero"

# Hours open to merge, through compute(): the stub returns no issue createdAt.
hours() {
  node -e '
    const { compute } = require(process.argv[1]);
    const r = compute({ prs: [
      { number: 1, body: "Closes #7", state: "MERGED", title: "x", createdAt: "2026-10-01T06:00:00Z", mergedAt: "2026-10-02T00:00:00Z" },
      { number: 2, body: "Closes #8", state: "MERGED", title: "x", createdAt: "2026-10-02T06:00:00Z", mergedAt: "2026-10-03T00:00:00Z" }],
      issues: JSON.parse(process.argv[2]), costs: null, last: 10 });
    const h = r.metrics.hoursOpenToMerge;
    process.stdout.write(`${h.label}:${h.value}`);' "$METRICS" "$1"
}
assert_eq "measured:18" "$(hours '{"7":{"createdAt":"2026-10-01T00:00:00Z"},"8":{"createdAt":"2026-10-02T12:00:00Z"}}')" "hours: the mean of merge minus issue open (24 h and 12 h)"
assert_eq "measured:24" "$(hours '{"7":{"createdAt":"2026-10-01T00:00:00Z"},"8":{"createdAt":"2026-10-02T00:00:00Z"}}')" "hours follow the issue open time (24 h and 24 h)"
assert_eq "unknown:null" "$(hours '{}')" "hours: no issue open time is unknown, not zero"

# --- the checker catches seeded defects ------------------------------------------

# seed <js mutating r> — run compute() on the base fixture, mutate, check.
prs CLOSED '[]'
seed() {
  node -e '
    const { compute } = require(process.argv[1]);
    const r = compute({ prs: JSON.parse(require("fs").readFileSync(process.argv[2], "utf8")), issues: {}, costs: null, last: 10 });
    (new Function("r", process.argv[3]))(r);
    require("fs").writeFileSync(process.argv[4], JSON.stringify(r));' "$METRICS" "$TMP/gh/prs.json" "$1" "$TMP/seed.json"
  node "$TMP/check.js" "$TMP/seed.json"
}
assert_eq "ok" "$(seed '')" "seed: the unmutated report passes"
assert_contains "$(seed 'r.metrics.reworkRate = { value: 0.5, label: "measured", display: "50%" };')" "reworkRate: no cited source" "seed: a metric with no cited source is caught"
assert_contains "$(seed 'r.metrics.costTotal = { value: 0, label: "measured", display: "$0.00" };')" "costTotal: zero without a measurement behind it" "seed: a zero with nothing counted is caught"
assert_contains "$(seed 'r.metrics.hoursOpenToMerge.value = 0;')" "hoursOpenToMerge: unknown but carries value 0" "seed: an unknown carrying zero is caught"
assert_contains "$(seed 'delete r.metrics.prsPerPackage.label;')" "prsPerPackage: label is undefined" "seed: an unlabeled metric is caught"
assert_contains "$(seed 'r.metrics.hoursOpenToMerge.note = "";')" "hoursOpenToMerge: unknown without a note" "seed: an unknown with no reason is caught"
assert_contains "$(seed 'delete r.metrics.stampCurrency;')" "stampCurrency: missing from the report" "seed: a dropped metric is caught"

finish
