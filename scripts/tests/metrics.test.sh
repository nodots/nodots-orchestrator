#!/usr/bin/env bash
# Fixture test for scripts/metrics.js: every value is labeled measured,
# estimated or unknown; a missing source is unknown, never zero; a total built
# from an estimate is an estimate. gh is the fleet stub (plugins/fleet/tests/stubs/gh.js).
set -uo pipefail
cd "$(dirname "$0")"
. ../../plugins/fleet/tests/lib.sh

METRICS="$(cd .. && pwd -P)/metrics.js"
GH="$(cd ../../plugins/fleet/tests/stubs && pwd -P)/gh.js"
assert_file "$METRICS" "scripts/metrics.js exists"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/gh" "$TMP/state/logs"
export GH_STUB_DIR="$TMP/gh" GH_BIN="$GH"

S1=1111111111111111111111111111111111111111
S2=2222222222222222222222222222222222222222
S3=3333333333333333333333333333333333333333
S4=4444444444444444444444444444444444444444
OLD=9999999999999999999999999999999999999999

# Packages 101..103. 101: one READY PR with a current stamp. 102: a closed PR,
# then a merged PR whose stamp names an older sha. 103: one PR with no stamp.
cat > "$TMP/gh/issues.json" <<EOF
[{"number":101,"title":"A1","body":"","labels":[],"state":"CLOSED"},
 {"number":102,"title":"A2","body":"","labels":[],"state":"CLOSED"},
 {"number":103,"title":"A3","body":"","labels":[],"state":"CLOSED"}]
EOF
cat > "$TMP/gh/prs.json" <<EOF
[{"number":1,"title":"[READY]: A1 one","body":"Closes #101","state":"MERGED","headRefOid":"$S1","createdAt":"2026-10-01T00:00:00Z","mergedAt":"2026-10-02T00:00:00Z","comments":[{"body":"VERIFIED: unit @ $S1\n\nnpm test"}]},
 {"number":2,"title":"[READY]: A2 first try","body":"Closes #102","state":"CLOSED","headRefOid":"$S2","createdAt":"2026-10-03T00:00:00Z","comments":[]},
 {"number":3,"title":"[READY]: A2 second try","body":"Closes #102","state":"MERGED","headRefOid":"$S3","createdAt":"2026-10-04T00:00:00Z","mergedAt":"2026-10-05T00:00:00Z","comments":[{"body":"VERIFIED: unit @ $OLD"}]},
 {"number":4,"title":"[READY]: A3 three","body":"Closes #103","state":"MERGED","headRefOid":"$S4","createdAt":"2026-10-06T00:00:00Z","mergedAt":"2026-10-07T00:00:00Z","comments":[]}]
EOF

run() { OUT=$(node "$METRICS" --repo acme/api "$@" 2>&1); RC=$?; }

run --last 10
assert_eq "0" "$RC" "the collector exits 0 on a readable fixture"
assert_contains "$OUT" "first-pass merge rate: 66.7% (2 of 3 packages) [measured]" "first-pass merge rate"
assert_contains "$OUT" "PRs per package: 1.33 (4 PRs, 3 packages) [measured]" "PRs per package"
assert_contains "$OUT" "stamp currency: 25.0% (1 of 4 READY PRs) [measured]" "stamp currency"
assert_contains "$OUT" "hours open to merge: unknown [unknown]" "issue creation time not exposed: hours are unknown"
assert_contains "$OUT" "cost per merged package: unknown [unknown]" "no cost data: cost per package is unknown"
assert_contains "$OUT" "cost total: unknown [unknown]" "no cost data: cost total is unknown"
assert_not_contains "$OUT" '$0' "unknown cost never prints as zero"

# Every metric line (not the # header) carries exactly one of the three labels.
BAD=$(printf '%s\n' "$OUT" | grep -v '^#' | grep -v -E '\[(measured|estimated|unknown)\]$' | wc -l | tr -d ' ')
assert_eq "0" "$BAD" "every value line ends with measured, estimated or unknown"

run --last 1
assert_contains "$OUT" "first-pass merge rate: 100.0% (1 of 1 packages) [measured]" "--last 1 keeps the most recently merged package (103)"

# Cost from fleet logs. 101 attempt 1 recorded; 102 attempts 1 and 3 recorded,
# attempt 2 has no result line (a gap); 103 has no log.
printf 'noise line\n{"type":"result","is_error":false,"total_cost_usd":0.5}\n' > "$TMP/state/logs/101-1.log"
printf '{"type":"result","is_error":false,"total_cost_usd":0.25}\n' > "$TMP/state/logs/102-1.log"
printf '{"type":"result","is_error":false,"total_cost_usd":0.25}\n' > "$TMP/state/logs/102-3.log"
run --last 10 --state-dir "$TMP/state"
assert_contains "$OUT" "cost total: \$1.00 (2 of 3 packages have log cost) [estimated]" "measured and estimated package costs: the total is estimated"
assert_contains "$OUT" "cost per merged package: \$0.50 (mean of 2 packages with log cost) [estimated]" "cost per package built from partial coverage is estimated"
assert_contains "$OUT" "package 101 cost: \$0.50 [measured]" "a fully logged package is measured"
assert_contains "$OUT" "package 102 cost: \$0.50 [estimated]" "a package with a missing attempt log is estimated"
assert_contains "$OUT" "package 103 cost: unknown [unknown]" "a package with no log is unknown"

# A log with no parseable result is unknown for that package, not zero.
printf 'killed before it printed a result\n' > "$TMP/state/logs/103-1.log"
run --last 10 --state-dir "$TMP/state"
assert_contains "$OUT" "package 103 cost: unknown [unknown]" "a log without a result line is unknown"

# Every package fully logged: the total is measured.
printf '{"type":"result","total_cost_usd":0.25}\n' > "$TMP/state/logs/102-2.log"
printf '{"type":"result","total_cost_usd":0.1}\n' > "$TMP/state/logs/103-1.log"
run --last 10 --state-dir "$TMP/state"
assert_contains "$OUT" "cost total: \$1.35 (3 of 3 packages have log cost) [measured]" "all packages measured: the total is measured"

# JSON mode carries the same labels.
run --last 10 --json
LAB=$(printf '%s' "$OUT" | node -e 'const m=JSON.parse(require("fs").readFileSync(0,"utf8")).metrics; process.stdout.write(Object.values(m).every(v=>["measured","estimated","unknown"].includes(v.label))?"ok":"bad")')
assert_eq "ok" "$LAB" "--json: every metric has a label"

# Module level: hours open to merge when the issue creation time is present.
HRS=$(node -e '
  const { compute } = require(process.argv[1]);
  const r = compute({ prs: [
    { number: 1, body: "Closes #7", state: "MERGED", title: "x", mergedAt: "2026-10-02T00:00:00Z", createdAt: "2026-10-01T12:00:00Z" },
    { number: 2, body: "Closes #8", state: "MERGED", title: "x", mergedAt: "2026-10-03T00:00:00Z", createdAt: "2026-10-02T00:00:00Z" }],
    issues: { 7: { createdAt: "2026-10-01T00:00:00Z" }, 8: {} }, costs: null, last: 10 });
  const h = r.metrics.hoursOpenToMerge;
  process.stdout.write(`${h.label}:${h.value}`);' "$METRICS")
assert_eq "estimated:24" "$HRS" "hours: one of two packages lacks an issue time, so the mean is estimated"

# gh failure is an error, not an empty report.
GH_BIN=/nonexistent/gh run --last 10
assert_ne "0" "$RC" "an unreadable tracker exits non-zero rather than reporting zeros"

OUT=$(node "$METRICS" --last 10 2>&1); RC=$?
assert_ne "0" "$RC" "missing --repo is a usage error"

finish
