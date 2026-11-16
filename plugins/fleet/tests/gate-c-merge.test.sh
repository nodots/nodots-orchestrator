#!/usr/bin/env bash
# CV gate, program C end to end through `fleet cycle --apply`: a fixture fleet
# whose target names integrationBranch collection/t with autoMerge branches its
# worker from collection/t, merges the stamped, green PR into it with a merge
# commit, then promotes and launches the dependent package from collection/t,
# which by then holds the first package's commit. Beside it, three stamped PRs
# that must not merge: one with a failing check (held, the check named), one
# whose base is development (merge-protected-refused) and one whose head moves
# after its checks pass (not merged that cycle).
#
# Fixture: a bare remote with development (its default branch) and
# collection/t, the real sync-cells.sh and assign-cells.sh, and the gh and
# claude stubs. The gh stub records a merge and flips the PR to MERGED; it does
# not touch git. The suite plays GitHub's side of the merge: once the stub has
# logged the merge, and only then, it merges the PR's branch into collection/t
# on the remote with --no-ff. It also plays the worker's `gh pr create --base`,
# which the claude stub does not record, by setting the PR's baseRefName.
#
# Packages: T1.1 (#10) queued for worker a; T1.2 (#11) depends on T1.1's branch;
# T1.3 (#12, red check), T1.4 (#13, base development) and T1.5 (#14, head moves)
# each with a PR open already, owned by worker x, which this machine does not run.
set -uo pipefail
cd "$(dirname "$0")"
. ./lib.sh

HERE=$(pwd -P)
FLEET="$(cd .. && pwd -P)/bin/fleet.js"
SRC="$(cd .. && pwd -P)/src"
PLUGIN="$(cd ../../agentic-work-packages && pwd -P)"
assert_file "$FLEET" "fleet.js exists"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
TMP=$(cd "$TMP" && pwd -P)

# --- a bare remote with development and collection/t ---------------------------
git init -q --bare -b development "$TMP/api.git"
git clone -q "$TMP/api.git" "$TMP/api" 2>/dev/null
git -C "$TMP/api" checkout -q -b development 2>/dev/null || true
git -C "$TMP/api" config user.email f@example.invalid; git -C "$TMP/api" config user.name fixture
printf '# api\n' > "$TMP/api/README.md"
git -C "$TMP/api" add -A && git -C "$TMP/api" commit -qm init
fixture_standards "$TMP/api" && git -C "$TMP/api" push -q -u origin development
git -C "$TMP/api" push -q origin development:collection/t
COLL0=$(git --git-dir "$TMP/api.git" rev-parse collection/t)

# --- stubs ---------------------------------------------------------------------
STUB="$TMP/stub"; mkdir -p "$STUB" "$TMP/gh" "$TMP/claude-log"
cp "$HERE/stubs/gh.js" "$STUB/gh.js"
printf '#!/usr/bin/env bash\nexec node "%s/gh.js" "$@"\n' "$STUB" > "$STUB/gh"; chmod +x "$STUB/gh"
cp "$HERE/stubs/claude.sh" "$STUB/claude"; chmod +x "$STUB/claude"
export GH_STUB_DIR="$TMP/gh" GH_STUB_REMOTE="$TMP/api.git" CLAUDE_STUB_LOG="$TMP/claude-log" CLAUDE_STUB_TARGET="acme/api"
export GH_BIN="$STUB/gh" CLAUDE_BIN="$STUB/claude"
export CLAUDE_CONFIG_FILE="$TMP/claude.json"
export CLAUDE_STUB_MODE_T1_1=pr CLAUDE_STUB_MODE_T1_2=silent
node -e "require('fs').writeFileSync('$TMP/claude.json', JSON.stringify({projects:{['$TMP/api']:{hasTrustDialogAccepted:true}}}))"
unset CLAUDECODE

H3=3333333333333333333333333333333333333333
H4=4444444444444444444444444444444444444444
H5=5555555555555555555555555555555555555555
H6=6666666666666666666666666666666666666666

scope_body() { # branch depends-on-json
  printf '**Part of** #1 · **Phase 0 · x** · **Repo:** `acme/api`\n\n## Goal\nx\n\n### SCOPE.json\n```json\n{"feature":"f","branch":"%s","allowedPaths":["src/**"],"forbiddenPaths":[],"dependsOn":%s,"execution":{"model":"default","pattern":"solo"}}\n```\n' "$1" "$2"
}
node - "$TMP/gh" "$H3" "$H4" "$H5" "$H6" \
  "$(scope_body feat/t1-1 '[]' | base64 -w0)" "$(scope_body feat/t1-2 '["feat/t1-1"]' | base64 -w0)" \
  "$(scope_body feat/t1-3 '[]' | base64 -w0)" "$(scope_body feat/t1-4 '[]' | base64 -w0)" "$(scope_body feat/t1-5 '[]' | base64 -w0)" <<'JS'
const fs = require('fs'); const [dir, h3, h4, h5, h6, ...bodies] = process.argv.slice(2);
const [b1, b2, b3, b4, b5] = bodies.map(s => Buffer.from(s, 'base64').toString());
fs.writeFileSync(`${dir}/issues.json`, JSON.stringify([
  { number: 1, title: 'Epic: program T', body: '', state: 'OPEN', labels: ['epic'] },
  { number: 10, title: 'T1.1 First package', body: b1, state: 'OPEN', labels: ['agent-ready', 'cell:queued', 'worker:a'] },
  { number: 11, title: 'T1.2 Depends on T1.1', body: b2, state: 'OPEN', labels: ['agent-ready'] },
  { number: 12, title: 'T1.3 Red check', body: b3, state: 'OPEN', labels: ['agent-ready', 'cell:active', 'worker:x'] },
  { number: 13, title: 'T1.4 Protected base', body: b4, state: 'OPEN', labels: ['agent-ready', 'cell:active', 'worker:x'] },
  { number: 14, title: 'T1.5 Head moves', body: b5, state: 'OPEN', labels: ['agent-ready', 'cell:active', 'worker:x'] },
], null, 2));
const pr = (n, issue, branch, head, x) => ({ number: n, title: `[READY]: T1.${issue - 9} done`, body: `Closes #${issue}`, state: 'OPEN',
  baseRefName: 'collection/t', headRefName: branch, headRefOid: head, mergeable: 'MERGEABLE', isDraft: false, url: `https://example.invalid/pr/${n}`, repo: 'acme/api', ...x });
fs.writeFileSync(`${dir}/prs.json`, JSON.stringify([
  pr(300, 12, 'feat/t1-3', h3, {}),
  pr(301, 13, 'feat/t1-4', h4, { baseRefName: 'development' }),
  pr(302, 14, 'feat/t1-5', h5, { pushAfterChecks: h6 }),
], null, 2));
const stamp = h => [{ id: 1, body: `VERIFIED: test @ ${h}\n\ntest: true\nok`, created_at: '2026-11-16T00:00:00Z' }];
fs.writeFileSync(`${dir}/comments.json`, JSON.stringify({ 'acme/api#300': stamp(h3), 'acme/api#301': stamp(h4), 'acme/api#302': stamp(h5) }, null, 2));
const green = [{ name: 'test', state: 'SUCCESS', bucket: 'pass' }];
fs.writeFileSync(`${dir}/checks.json`, JSON.stringify({
  'acme/api#300': [{ name: 'test', state: 'FAILURE', bucket: 'fail' }, { name: 'lint', state: 'SUCCESS', bucket: 'pass' }],
  'acme/api#301': green, 'acme/api#302': green,
}, null, 2));
fs.writeFileSync(`${dir}/labels.json`, '{}'); fs.writeFileSync(`${dir}/writes.log`, '');
JS
printf '{}' > "$TMP/gh/ci.json"

cat > "$TMP/fleet.config.json" <<JSON
{
  "repo": "acme/host", "epic": 1,
  "targets": [{ "repo": "acme/api", "localPath": "$TMP/api", "defaultBranch": "development", "integrationBranch": "collection/t", "autoMerge": true }],
  "workers": { "a": { "mode": "local" } },
  "wipCap": 4, "worktreesDir": "$TMP/worktrees", "stateDir": "$TMP/state",
  "pluginRoot": "$PLUGIN", "noMovementLimit": 99
}
JSON
fleet() { node "$FLEET" "$@" --config "$TMP/fleet.config.json"; }
cycle() { OUT=$(fleet cycle --apply --json 2>"$TMP/cycle.err"); EXIT=$?; }
jq_out() { printf '%s' "$OUT" | node -e "const r=JSON.parse(require('fs').readFileSync(0,'utf8')); console.log($1)"; }
launched() { jq_out "r.launched.map(l=>l.id).sort().join(' ')"; }
note() { jq_out "(r.merge||[]).filter(m=>m.pr===$1).map(m=>m.action+': '+(m.detail||'')).join(' | ')"; }
alarm_codes() { jq_out "r.alarms.map(a=>a.code).sort().join(' ')"; }
alarm_detail() { jq_out "r.alarms.filter(a=>a.code==='$1').map(a=>a.detail).join(' | ')"; }
rendered() { printf '%s' "$OUT" | node -e "const r=JSON.parse(require('fs').readFileSync(0,'utf8')); process.stdout.write(require('$SRC/report.js').render(r))"; }
merges() { grep '^merge ' "$TMP/gh/writes.log" | sort | tr '\n' '|'; }
pr_field() { node -e "const p=JSON.parse(require('fs').readFileSync('$TMP/gh/prs.json','utf8')).find(x=>x.headRefName==='$1'); console.log(p ? p[process.argv[1]] : '')" "$2"; }
labels_of() { node -e "const o=JSON.parse(require('fs').readFileSync('$TMP/gh/labels.json','utf8'))[$1]; console.log(o ? o.filter(l=>l.startsWith('cell:')).join(' ') : '(unchanged)')"; }
# A PR registered by the claude stub on <branch>: poll prs.json, the stub runs detached.
wait_for_pr() {
  local i=0
  until [ -n "$(pr_field "$1" number)" ]; do
    [ "$i" -ge 150 ] && return 1
    sleep 0.1; i=$((i + 1))
  done
}

# --- cycle 1: T1.1 launches from collection/t ----------------------------------
cycle
assert_eq "0" "$EXIT" "1: the first cycle exits 0"
assert_eq "T1.1" "$(launched)" "1: T1.1 launches; T1.2 waits on its dependency"
assert_contains "$(jq_out "(r.held||[]).filter(h=>h.number===11).map(h=>h.why).join()")" "waiting on feat/t1-1" "1: T1.2 is held waiting on feat/t1-1"
wait_for_file "$TMP/claude-log/T1.1.*.argv"
ARGV=$(cat "$TMP"/claude-log/T1.1.*.argv 2>/dev/null)
assert_contains "$ARGV" "Open the PR against collection/t with a title" "1: the prompt names collection/t as the PR base"
assert_not_contains "$ARGV" "Open the PR against development" "1: and not development"
wait_for_pr feat/t1-1
PR1=$(pr_field feat/t1-1 number)
HEAD1=$(pr_field feat/t1-1 headRefOid)
assert_nonempty "$PR1" "1: the T1.1 worker opened a PR"
assert_eq "$HEAD1" "$(git --git-dir "$TMP/api.git" rev-parse feat/t1-1 2>/dev/null)" "1: the PR head is the pushed feat/t1-1"
# The branch is collection/t, then fleet's scope commit (launch.js), then the worker's.
assert_eq "T1.1: scope" "$(git --git-dir "$TMP/api.git" log -1 --format=%s "$HEAD1~1" 2>/dev/null)" "1: under the worker's commit is fleet's scope commit"
assert_eq "$COLL0" "$(git --git-dir "$TMP/api.git" rev-parse "$HEAD1~2" 2>/dev/null)" "1: T1.1's worktree started from collection/t"
WT1=$(jq_out "r.launched.find(l=>l.id==='T1.1').worktree")
assert_eq "feat/t1-1" "$(git -C "$WT1" rev-parse --abbrev-ref HEAD 2>/dev/null)" "1: the worktree is on the package branch"
assert_eq "" "$(merges)" "1: nothing is merged in the first cycle"

# The three fixture PRs are open, stamped and on their bases from the start, so
# the merge stage judges them in this first cycle.
# Held: a stamped PR with a failing check stays open, and the report names the check.
assert_eq "OPEN" "$(pr_field feat/t1-3 state)" "4: the PR with a failing check is not merged"
assert_contains "$(note 300)" "held: gh pr checks not all green: test fail" "4: the report names the failing check"
assert_not_contains "$(note 300)" "lint" "4: and not the passing one"
assert_contains "$(rendered)" "acme/api#300: held" "4: the rendered report lists it as held"
assert_contains "$(rendered)" "test fail" "4: and names the check"

# Protected: a stamped, green PR on development is refused.
assert_eq "OPEN" "$(pr_field feat/t1-4 state)" "5: the green, stamped PR on development is not merged"
assert_contains "$(alarm_codes)" "merge-protected-refused" "5: merge-protected-refused is raised"
assert_contains "$(alarm_detail merge-protected-refused)" "#301 (T1.4) has base development" "5: the alarm names the PR and its base"
assert_eq "13" "$(jq_out "r.alarms.find(a=>a.code==='merge-protected-refused').issue")" "5: the alarm names the package issue"
assert_eq "0" "$(grep -c '^merge-attempt acme/api 301' "$TMP/gh/writes.log")" "5: no merge of it is attempted"
assert_eq "alarm" "$(jq_out r.outcome)" "5: the refusal makes the cycle an alarm, beside the launch"

# Moved head: the push after the checks keeps the PR from merging this cycle.
assert_eq "OPEN" "$(pr_field feat/t1-5 state)" "6: the PR whose head moved after its checks is not merged"
assert_eq "$H6" "$(pr_field feat/t1-5 headRefOid)" "6: its head moved once the checks were read"
assert_eq "1" "$(grep -c "^merge-attempt acme/api 302 --merge --match-head-commit $H5" "$TMP/gh/writes.log")" "6: the one attempt names the head the checks passed on"
assert_contains "$(alarm_detail merge-failed)" "#302 (T1.5)" "6: merge-failed names the PR"
assert_contains "$(alarm_detail merge-failed)" "Head branch was modified" "6: with gh's message"
assert_contains "$(note 302)" "failed:" "6: the report notes the failure"

# The worker's `gh pr create --base collection/t`; then its stamp, and CI goes green.
node - "$TMP/gh" "$PR1" "$HEAD1" <<'JS'
const fs = require('fs'); const [dir, n, head] = process.argv.slice(2);
const prs = JSON.parse(fs.readFileSync(`${dir}/prs.json`, 'utf8'));
const p = prs.find(x => x.number === Number(n)); p.baseRefName = 'collection/t'; p.mergeable = 'MERGEABLE';
fs.writeFileSync(`${dir}/prs.json`, JSON.stringify(prs, null, 2));
const c = JSON.parse(fs.readFileSync(`${dir}/comments.json`, 'utf8'));
c[`acme/api#${n}`] = [{ id: 9, body: `VERIFIED: test @ ${head}\n\ntest: true\nok`, created_at: '2026-11-16T01:00:00Z' }];
fs.writeFileSync(`${dir}/comments.json`, JSON.stringify(c, null, 2));
const k = JSON.parse(fs.readFileSync(`${dir}/checks.json`, 'utf8'));
k[`acme/api#${n}`] = [{ name: 'test', state: 'SUCCESS', bucket: 'pass' }];
fs.writeFileSync(`${dir}/checks.json`, JSON.stringify(k, null, 2));
JS
# Let the detached worker finish before the next cycle reaps it.
for _ in $(seq 1 100); do kill -0 "$(jq_out "r.launched.find(l=>l.id==='T1.1').pid")" 2>/dev/null || break; sleep 0.1; done

# --- cycle 2: T1.1 merges; T1.3, T1.4 and T1.5 still do not --------------------
cycle
assert_eq "merge acme/api $PR1 --merge --match-head-commit $HEAD1|" "$(merges)" "2: only T1.1's PR is merged, with --merge (a merge commit) at the checked head"
assert_eq "MERGED" "$(pr_field feat/t1-1 state)" "2: T1.1's PR is merged"
assert_contains "$(note "$PR1")" "merged: T1.1 at ${HEAD1:0:7} into collection/t" "2: the report notes T1.1 merged into collection/t"
assert_contains "$(rendered)" "acme/api#$PR1: merged" "2: the rendered report lists the merge"
assert_contains "$(note 300)" "held: gh pr checks not all green: test fail" "4: the red PR is held again the next cycle"
assert_contains "$(alarm_detail merge-protected-refused)" "#301 (T1.4)" "5: the development PR is refused again the next cycle"
assert_eq "alarm" "$(jq_out r.outcome)" "5: the refusal makes the cycle an alarm, beside the merge"
assert_eq "OPEN" "$(pr_field feat/t1-5 state)" "6: the moved PR is still not merged the next cycle"
assert_contains "$(note 302)" "held: no current VERIFIED stamp at ${H6:0:7}" "6: it waits for a stamp at the new head"
assert_eq "1" "$(grep -c '^merge-attempt acme/api 302' "$TMP/gh/writes.log")" "6: and no second merge is attempted"

# GitHub's side of the merge, only for a merge the stub logged: a merge commit on collection/t.
if grep -q "^merge acme/api $PR1 " "$TMP/gh/writes.log"; then
  git -C "$TMP/api" fetch -q origin
  git -C "$TMP/api" checkout -q -B collection/t origin/collection/t
  git -C "$TMP/api" merge -q --no-ff -m "Merge pull request #$PR1 from feat/t1-1" origin/feat/t1-1
  git -C "$TMP/api" push -q origin collection/t
  git -C "$TMP/api" checkout -q development
fi
COLL1=$(git --git-dir "$TMP/api.git" rev-parse collection/t)
assert_eq "$COLL0 $HEAD1" "$(git --git-dir "$TMP/api.git" log -1 --format=%P "$COLL1")" "2: collection/t's head is a merge commit of T1.1 onto collection/t"

# --- cycle 3: the sync derives cell:merged; T1.2 is promoted and launched --------
cycle
assert_contains "$(jq_out "r.sync.changes.filter(c=>c.number===10).map(c=>c.to+' '+c.why).join()")" "cell:merged PR #$PR1 merged (into collection/t)" "2: the sync derives cell:merged for T1.1, into collection/t"
assert_eq "cell:merged" "$(labels_of 10)" "2: T1.1's label is cell:merged"
assert_contains "$(jq_out "r.promoted.map(p=>p.number+' '+p.add+' '+p.why).join()")" "11 cell:queued all of feat/t1-1 merged" "3: T1.2 is promoted once feat/t1-1 merged"
assert_eq "T1.2" "$(launched)" "3: T1.2 is launched"
wait_for_file "$TMP/claude-log/T1.2.*.argv"
assert_contains "$(cat "$TMP"/claude-log/T1.2.*.argv 2>/dev/null)" "Open the PR against collection/t with a title" "3: T1.2's prompt names collection/t as the PR base"
WT2=$(jq_out "r.launched.find(l=>l.id==='T1.2').worktree")
assert_eq "T1.2: scope" "$(git -C "$WT2" log -1 --format=%s HEAD 2>/dev/null)" "3: T1.2's worktree head is fleet's scope commit"
assert_eq "$COLL1" "$(git -C "$WT2" rev-parse HEAD~1 2>/dev/null)" "3: T1.2's worktree starts from collection/t after the merge"
git -C "$WT2" merge-base --is-ancestor "$HEAD1" HEAD 2>/dev/null \
  && _pass "3: T1.2's worktree holds T1.1's commit" || _fail "3: T1.2's worktree holds T1.1's commit" "$HEAD1 is not an ancestor of $(git -C "$WT2" rev-parse HEAD 2>/dev/null)"
assert_file "$WT2/src/T1.1.txt" "3: and T1.1's file"

finish
