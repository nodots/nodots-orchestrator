#!/usr/bin/env bash
# Shape test for evals/cases/*.json: at least 20 valid cases, every incident
# case cites its PR and quoted failure, and each skill has at least 3 trigger
# phrasings plus a near-miss. No model is called.
set -uo pipefail
cd "$(dirname "$0")"
. ../../plugins/fleet/tests/lib.sh

ROOT="$(cd ../.. && pwd -P)"
CASES="${EVAL_CASES_DIR:-$ROOT/evals/cases}"

# Cases whose file name starts with _ are examples, not counted.
REPORT=$(node -e '
  const fs = require("fs"), path = require("path");
  const { validateCase } = require(process.argv[1] + "/evals/lib/cases.js");
  const dir = process.argv[2];
  const out = { valid: 0, errors: [], ids: [], incidentBad: [], triggers: {}, contract: 0 };
  let names = [];
  try { names = fs.readdirSync(dir).filter(n => n.endsWith(".json") && !n.startsWith("_")).sort(); }
  catch (e) { out.errors.push("cannot read " + dir); }
  for (const n of names) {
    let c;
    try { c = validateCase(JSON.parse(fs.readFileSync(path.join(dir, n), "utf8")), n); }
    catch (e) { out.errors.push(e.message); continue; }
    out.valid++;
    out.ids.push(c.id);
    if (c.id !== path.basename(n, ".json")) out.errors.push(n + ": id " + c.id + " does not match the file name");
    if (c.id.startsWith("incident-")) {
      const s = c.source || {};
      if (!Number.isInteger(s.pr) || typeof s.quote !== "string" || !s.quote.trim()) out.incidentBad.push(c.id);
    }
    const m = /^trigger-(awp|fleet)-(positive|near-miss)-/.exec(c.id);
    if (m) {
      out.triggers[m[1]] = out.triggers[m[1]] || { positive: 0, nearMiss: 0 };
      out.triggers[m[1]][m[2] === "positive" ? "positive" : "nearMiss"]++;
    }
    if (c.id.startsWith("contract-")) out.contract++;
  }
  if (new Set(out.ids).size !== out.ids.length) out.errors.push("duplicate ids");
  console.log(JSON.stringify(out));
' "$ROOT" "$CASES")

field() { node -p "const r=$REPORT; $1" 2>&1; }

assert_eq "0" "$(field 'r.errors.length')" "every case file validates (errors: $(field 'r.errors.join("; ")'))"
VALID=$(field 'r.valid')
if [ "$VALID" -ge 20 ] 2>/dev/null; then _pass "at least 20 valid cases ($VALID)"; else _fail "at least 20 valid cases" "found $VALID"; fi
assert_eq "" "$(field 'r.incidentBad.join(",")')" "every incident case cites a PR number and a quoted failure"
assert_eq "true" "$(field '(r.ids.filter(i=>i.startsWith("incident-")).length >= 8)')" "at least 8 incident cases"
for s in awp fleet; do
  assert_eq "true" "$(field "((r.triggers.$s||{positive:0}).positive >= 3)")" "$s: at least 3 trigger phrasings"
  assert_eq "true" "$(field "((r.triggers.$s||{nearMiss:0}).nearMiss >= 1)")" "$s: at least 1 near-miss"
done
assert_eq "true" "$(field '(r.contract >= 2)')" "at least 2 worker-contract cases"

finish
