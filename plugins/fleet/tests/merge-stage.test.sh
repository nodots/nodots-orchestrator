#!/usr/bin/env bash
# The merge stage (src/merge.js): for a target with autoMerge, the cycle merges
# each open package PR whose base is the target's integrationBranch and that
# meets the merge condition, with `gh pr merge --merge --match-head-commit`. A
# PR whose base is protected is refused merge-protected-refused before anything
# else is checked. Each unmet condition leaves the PR open and the report names
# it; a head that moved after the checks is not merged; the dry run merges
# nothing. Driven end to end through `fleet cycle` against a real git remote,
# the plugin scripts and the gh stub; the review condition through the stage
# itself, with a policy and without a reviewMet export.
set -uo pipefail
cd "$(dirname "$0")"
. ./lib.sh

HERE=$(pwd -P)
FLEET="$(cd .. && pwd -P)/bin/fleet.js"
SRC="$(cd .. && pwd -P)/src"
PLUGIN="$(cd ../../agentic-work-packages && pwd -P)"
assert_file "$FLEET" "fleet.js exists"
assert_file "$SRC/merge.js" "merge.js exists"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
TMP=$(cd "$TMP" && pwd -P)

# --- a real remote with main and the integration branch integ ------------------
git init -q --bare -b main "$TMP/api.git"
git clone -q "$TMP/api.git" "$TMP/api" 2>/dev/null
git -C "$TMP/api" checkout -q -b main 2>/dev/null || true
git -C "$TMP/api" config user.email f@example.invalid; git -C "$TMP/api" config user.name fixture
printf '# api\n' > "$TMP/api/README.md"
git -C "$TMP/api" add -A && git -C "$TMP/api" commit -qm init && git -C "$TMP/api" push -q -u origin main
git -C "$TMP/api" push -q origin main:integ

# --- stubs -------------------------------------------------------------------
STUB="$TMP/stub"; mkdir -p "$STUB" "$TMP/gh"
cp "$HERE/stubs/gh.js" "$STUB/gh.js"
printf '#!/usr/bin/env bash\nexec node "%s/gh.js" "$@"\n' "$STUB" > "$STUB/gh"; chmod +x "$STUB/gh"
export GH_STUB_DIR="$TMP/gh" GH_STUB_REMOTE="$TMP/api.git" GH_BIN="$STUB/gh"
unset CLAUDECODE

# Two packages: T1.1 (#10) and T1.2 (#11), whose PRs are #200 and #201.
scope_body() { # branch
  printf '**Part of** #1 · **Phase 0 · x** · **Repo:** `acme/api`\n\n## Goal\nx\n\n### SCOPE.json\n```json\n{"feature":"f","branch":"%s","allowedPaths":["src/**"],"forbiddenPaths":[],"dependsOn":[],"execution":{"model":"default","pattern":"solo"}}\n```\n' "$1"
}
node - "$TMP/gh" "$(scope_body feat/t1-1 | base64 -w0)" "$(scope_body feat/t1-2 | base64 -w0)" <<'JS'
const fs = require('fs'); const [dir, b1, b2] = process.argv.slice(2);
const b = s => Buffer.from(s, 'base64').toString();
fs.writeFileSync(`${dir}/issues.json`, JSON.stringify([
  { number: 1, title: 'Epic: program T', body: '', state: 'OPEN', labels: ['epic'] },
  { number: 10, title: 'T1.1 Package one', body: b(b1), state: 'OPEN', labels: ['agent-ready', 'cell:active', 'worker:x'] },
  { number: 11, title: 'T1.2 Package two', body: b(b2), state: 'OPEN', labels: ['agent-ready', 'cell:active', 'worker:x'] },
], null, 2));
JS

H1=1111111111111111111111111111111111111111
H2=2222222222222222222222222222222222222222
H3=3333333333333333333333333333333333333333

# reset [pr200-extra-json] [pr201-extra-json]: both PRs open on integ, mergeable,
# stamped at their heads and green; the extras override fields of each.
reset() {
  node - "$TMP/gh" "$H1" "$H2" "${1:-{\}}" "${2:-{\}}" <<'JS'
const fs = require('fs'); const [dir, h1, h2, x1, x2] = process.argv.slice(2);
const pr = (n, issue, branch, head, x) => ({ number: n, title: `[READY]: T1.${issue - 9} done`, body: `Closes #${issue}`, state: 'OPEN',
  baseRefName: 'integ', headRefName: branch, headRefOid: head, mergeable: 'MERGEABLE', isDraft: false, url: `https://example.invalid/pr/${n}`, repo: 'acme/api', ...JSON.parse(x) });
const prs = [pr(200, 10, 'feat/t1-1', h1, x1), pr(201, 11, 'feat/t1-2', h2, x2)];
fs.writeFileSync(`${dir}/prs.json`, JSON.stringify(prs, null, 2));
const stamp = h => [{ id: 1, body: `VERIFIED: test @ ${h}\n\ntest: true\nok`, created_at: '2026-11-16T00:00:00Z' }];
fs.writeFileSync(`${dir}/comments.json`, JSON.stringify({ 'acme/api#200': stamp(h1), 'acme/api#201': stamp(h2) }, null, 2));
const green = [{ name: 'test', state: 'SUCCESS', bucket: 'pass' }, { name: 'lint', state: 'SKIPPED', bucket: 'skipping' }];
fs.writeFileSync(`${dir}/checks.json`, JSON.stringify({ 'acme/api#200': green, 'acme/api#201': green }, null, 2));
fs.writeFileSync(`${dir}/labels.json`, '{}'); fs.writeFileSync(`${dir}/writes.log`, '');
JS
}
set_checks() { node -e "const f='$TMP/gh/checks.json',fs=require('fs');const a=JSON.parse(fs.readFileSync(f,'utf8'));a['acme/api#$1']=JSON.parse(process.argv[1]);fs.writeFileSync(f,JSON.stringify(a,null,2))" "$2"; }
drop_checks() { node -e "const f='$TMP/gh/checks.json',fs=require('fs');const a=JSON.parse(fs.readFileSync(f,'utf8'));delete a['acme/api#$1'];fs.writeFileSync(f,JSON.stringify(a,null,2))"; }

write_config() { # target-extra-json-fields
  cat > "$TMP/fleet.config.json" <<JSON
{
  "repo": "acme/host", "epic": 1,
  "targets": [{ "repo": "acme/api", "localPath": "$TMP/api", "defaultBranch": "main" $1 }],
  "workers": { "a": { "mode": "local" } },
  "wipCap": 4, "worktreesDir": "$TMP/worktrees", "stateDir": "$TMP/state",
  "pluginRoot": "$PLUGIN", "noMovementLimit": 99
}
JSON
}
AUTO=', "integrationBranch": "integ", "autoMerge": true'
fleet() { node "$FLEET" "$@" --config "$TMP/fleet.config.json"; }
cycle() { OUT=$(fleet cycle "$@" --json 2>"$TMP/cycle.err"); EXIT=$?; }
jq_out() { printf '%s' "$OUT" | node -e "const r=JSON.parse(require('fs').readFileSync(0,'utf8')); console.log($1)"; }
merges() { grep '^merge ' "$TMP/gh/writes.log" | sort | tr '\n' '|'; }
note() { jq_out "(r.merge||[]).filter(m=>m.pr===$1).map(m=>m.action+': '+(m.detail||'')).join(' | ')"; }
alarm_codes() { jq_out "r.alarms.map(a=>a.code).sort().join(' ')"; }
alarm_detail() { jq_out "r.alarms.filter(a=>a.code==='$1').map(a=>a.detail).join(' | ')"; }
pr_state() { node -e "console.log(require('$TMP/gh/prs.json').find(x=>x.number===$1).state)"; }
rendered() { printf '%s' "$OUT" | node -e "const r=JSON.parse(require('fs').readFileSync(0,'utf8')); process.stdout.write(require('$SRC/report.js').render(r))"; }

# --- A. stamped, green, mergeable, on integ: merged with --match-head-commit -----
write_config "$AUTO"
reset
cycle --apply
assert_eq "0" "$EXIT" "A: the cycle exits 0"
assert_eq "merge acme/api 200 --merge --match-head-commit $H1|merge acme/api 201 --merge --match-head-commit $H2|" "$(merges)" "A: both PRs are merged with --merge --match-head-commit <the checked head>"
assert_eq "MERGED MERGED" "$(pr_state 200) $(pr_state 201)" "A: both PRs are merged in the stub"
assert_eq "merged: T1.1 at 1111111 into integ" "$(note 200 | sed 's/ as [0-9a-f]*$//')" "A: the report notes #200 merged"
assert_eq "movement" "$(jq_out r.outcome)" "A: a merge is movement"
MV=$(jq_out "r.movement.filter(m=>m.artifact.type==='merged').map(m=>m.package+' '+m.artifact.ref).join(',')")
C37=ccccccccccccccccccccccccccccccccccccc
assert_eq "T1.1 ${C37}200,T1.2 ${C37}201" "$MV" "A: each movement records the merge commit sha"
R=$(rendered)
assert_contains "$R" "**Merged**" "A: the rendered report has a Merged section"
assert_contains "$R" "acme/api#200: merged" "A: the Merged section names the PR"
assert_eq "" "$(jq_out "r.alarms.filter(a=>/^merge-/.test(a.code)).map(a=>a.code).join()")" "A: no merge alarm"

# --- B. each missing condition leaves the PR open and names it -----------------
reset '{"headRefOid":"'"$H3"'"}'
cycle --apply
assert_eq "merge acme/api 201 --merge --match-head-commit $H2|" "$(merges)" "B1: a PR with no stamp at its head is not merged"
assert_eq "OPEN" "$(pr_state 200)" "B1: it stays open"
assert_contains "$(note 200)" "held: no current VERIFIED stamp at 3333333" "B1: the report names the stamp condition"

reset
set_checks 200 '[{"name":"test","state":"FAILURE","bucket":"fail"},{"name":"lint","state":"SUCCESS","bucket":"pass"}]'
cycle --apply
assert_eq "merge acme/api 201 --merge --match-head-commit $H2|" "$(merges)" "B2: a PR with a red check is not merged"
assert_contains "$(note 200)" "held: gh pr checks not all green: test fail" "B2: the report names the checks condition and the check"

reset
set_checks 200 '[{"name":"test","state":"IN_PROGRESS","bucket":"pending"}]'
cycle --apply
assert_eq "OPEN" "$(pr_state 200)" "B3: a PR with a pending check is not merged"
assert_contains "$(note 200)" "held: gh pr checks not all green: test pending" "B3: the report names the pending check"

reset
drop_checks 200
cycle --apply
assert_eq "OPEN" "$(pr_state 200)" "B4: a PR with no checks reported is not merged"
assert_contains "$(note 200)" "held: gh pr checks" "B4: the report names the checks condition"

reset '{"mergeable":"CONFLICTING"}'
cycle --apply
assert_eq "merge acme/api 201 --merge --match-head-commit $H2|" "$(merges)" "B5: a conflicting PR is not merged"
assert_contains "$(note 200)" "held: mergeable is CONFLICTING, not MERGEABLE" "B5: the report names the mergeable condition"

# The first unmet condition is the one named: no stamp and red checks names the stamp.
reset '{"headRefOid":"'"$H3"'","mergeable":"CONFLICTING"}'
set_checks 200 '[{"name":"test","state":"FAILURE","bucket":"fail"}]'
cycle --apply
assert_contains "$(note 200)" "no current VERIFIED stamp" "B6: the first unmet condition, in order, is named"
assert_not_contains "$(note 200)" "checks" "B6: and only that one"

# --- C. a PR whose base is protected is never merged ---------------------------
reset '' '{"baseRefName":"development"}'
cycle --apply
assert_eq "merge acme/api 200 --merge --match-head-commit $H1|" "$(merges)" "C: the PR on development is not merged, with every condition met"
assert_eq "OPEN" "$(pr_state 201)" "C: it stays open"
assert_contains "$(alarm_codes)" "merge-protected-refused" "C: merge-protected-refused is raised"
assert_contains "$(alarm_detail merge-protected-refused)" "#201" "C: the alarm names the PR"
assert_contains "$(alarm_detail merge-protected-refused)" "development" "C: the alarm names the protected base"
assert_eq "11" "$(jq_out "r.alarms.find(a=>a.code==='merge-protected-refused').issue")" "C: the alarm names the package issue"
assert_eq "alarm" "$(jq_out r.outcome)" "C: a refused protected merge makes the cycle an alarm, beside movement"
for b in main master develop; do
  reset '' '{"baseRefName":"'"$b"'"}'
  cycle --apply
  assert_eq "OPEN" "$(pr_state 201)" "C: a PR on $b is not merged either"
  assert_contains "$(alarm_codes)" "merge-protected-refused" "C: $b raises merge-protected-refused"
done
# A base outside the protected list and other than integ is neither merged nor refused.
reset '' '{"baseRefName":"feature-x"}'
cycle --apply
assert_eq "OPEN" "$(pr_state 201)" "C: a PR on another branch is not merged"
assert_not_contains "$(alarm_codes)" "merge-protected-refused" "C: and is not a protected refusal"
assert_contains "$(note 201)" "skipped: base feature-x is not the integration branch integ" "C: the report says why"
# The refusal comes first: merge.js asks for no check on a protected PR.
reset '' '{"baseRefName":"development"}'
: > "$TMP/gh/reads.log"
cycle --apply
assert_not_contains "$(cat "$TMP/gh/reads.log")" "checks acme/api 201" "C: no check is read for a protected PR"

# --- D. a head that moved after the checks is not merged -----------------------
reset '{"pushAfterChecks":"'"$H3"'"}'
cycle --apply
assert_eq "merge acme/api 201 --merge --match-head-commit $H2|" "$(merges)" "D: the moved PR is not merged"
assert_eq "OPEN" "$(pr_state 200)" "D: it stays open"
assert_contains "$(alarm_codes)" "merge-failed" "D: merge-failed is raised"
assert_contains "$(alarm_detail merge-failed)" "Head branch was modified" "D: the alarm carries gh's message"
assert_contains "$(note 200)" "failed:" "D: the report notes the failure"
assert_eq "1" "$(grep -c '^merge-attempt acme/api 200' "$TMP/gh/writes.log")" "D: nothing is retried within the cycle"

# --- E. the dry run merges nothing, and says what it would do ------------------
reset '' '{"mergeable":"CONFLICTING"}'
cycle
assert_eq "" "$(merges)" "E: the dry run merges nothing"
assert_eq "" "$(grep '^merge-attempt' "$TMP/gh/writes.log")" "E: the dry run attempts no merge"
assert_eq "OPEN OPEN" "$(pr_state 200) $(pr_state 201)" "E: both PRs stay open"
assert_contains "$(note 200)" "would-merge: T1.1 at 1111111 into integ" "E: the report says which PR would merge"
assert_contains "$(note 201)" "held: mergeable is CONFLICTING" "E: and why the other would not"
R=$(rendered)
assert_contains "$R" "acme/api#200: would-merge" "E: the rendered report lists the would-merge"
assert_contains "$R" "acme/api#201: held" "E: and the held PR"

# --- F. without autoMerge, nothing is merged and the report is unchanged --------
for extra in '' ', "integrationBranch": "integ"'; do
  write_config "$extra"
  reset
  : > "$TMP/gh/reads.log"
  cycle --apply
  assert_eq "" "$(merges)" "F: no merge without autoMerge [${extra:-no keys}]"
  assert_eq "" "$(jq_out "(r.merge||[]).length||''")" "F: no merge notes [${extra:-no keys}]"
  assert_eq "" "$(cat "$TMP/gh/reads.log")" "F: no PR view or checks read [${extra:-no keys}]"
  assert_not_contains "$(rendered)" "**Merged**" "F: no Merged section [${extra:-no keys}]"
done

# --- G. the review condition, through the stage itself --------------------------
write_config "$AUTO"
stage() { # policy-json scriptsDir
  node - "$SRC" "$TMP/fleet.config.json" "$1" "$2" <<'JS'
const [src, cfgPath, policy, scriptsDir] = process.argv.slice(2);
const { loadConfig } = require(`${src}/config.js`);
const { Tracker } = require(`${src}/tracker.js`);
const { stage } = require(`${src}/merge.js`);
const cfg = loadConfig(cfgPath);
if (scriptsDir) cfg.scriptsDir = scriptsDir;
const tracker = new Tracker(cfg.bins);
const pulls = tracker.listPulls('acme/api').pulls.map(p => ({ ...p, repo: 'acme/api' }));
const comments = n => tracker.listComments('acme/api', n).comments.map(c => c.body);
const sync = { state: { reviewPolicies: { 'acme/api': JSON.parse(policy) }, issues: [
  { number: 10, title: 'T1.1 Package one', repo: 'acme/api', pr: { number: 200, comments: comments(200) } },
  { number: 11, title: 'T1.2 Package two', repo: 'acme/api', pr: { number: 201, comments: comments(201) } },
] } };
const r = { merge: [], movement: [] }; const alarms = [];
stage({ cfg, apply: true, tracker, pulls, pullsFailed: new Set(), sync, alarm: (code, detail, issue) => alarms.push({ code, detail, issue }), r });
console.log(r.merge.map(m => `${m.pr} ${m.action}: ${m.detail}`).join('\n'));
JS
}
reset
node -e "const f='$TMP/gh/comments.json',fs=require('fs');const a=JSON.parse(fs.readFileSync(f,'utf8'));a['acme/api#201'].push({id:2,body:'REVIEWED: r1 @ $H2\n\nok',created_at:'x'});fs.writeFileSync(f,JSON.stringify(a,null,2))"
OUT=$(stage '{"passes":1}' "")
assert_contains "$OUT" "200 held: review policy not met: 0 of 1 REVIEWED stamp(s) at 1111111" "G: a PR short of its review policy is held, and the condition named"
assert_contains "$OUT" "201 merged:" "G: a PR that meets the policy merges"
assert_eq "merge acme/api 201 --merge --match-head-commit $H2|" "$(merges)" "G: only the reviewed PR is merged"

# A stamp.js without reviewMet: the check is skipped, and the report says so.
mkdir -p "$TMP/old-scripts"
cat > "$TMP/old-scripts/stamp.js" <<'JS'
'use strict';
const STAMP = /^VERIFIED:\s*(\S.*?)\s+@\s+([0-9a-f]{40})\s*$/m;
function currentStamp(pr) {
  for (const body of pr.comments || []) { const m = STAMP.exec(String(body)); if (m && m[2] === pr.headSha) return { suite: m[1], sha: m[2] }; }
  return null;
}
module.exports = { STAMP, currentStamp };
JS
reset
OUT=$(stage '{"passes":1}' "$TMP/old-scripts")
assert_contains "$OUT" "200 merged:" "G: without reviewMet the stage merges on VERIFIED alone"
assert_contains "$OUT" "review not checked: stamp.js has no reviewMet" "G: and the report says the review check was skipped"

finish
