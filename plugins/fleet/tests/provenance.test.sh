#!/usr/bin/env bash
# Label provenance (X0.3): with `coordinators` set, fleet acts on agent-ready,
# cell:* and worker:* only when a coordinator applied them.
#
# What is proved, through `fleet cycle` against a real git remote, the plugin
# scripts and the gh stub (whose timeline.json records who applied a label):
# a package whose worker:a came from another account raises
# label-foreign-actor and is neither labeled nor launched; an agent-ready from
# another account is not promoted; a coordinator's later re-label wins; a
# failed timeline read raises label-actors-failed and holds the package; a
# flagged cell:active package still counts toward wipCap, and its open PR is
# neither reviewed nor merged; coordinators without fleet's own login is
# config-invalid and promotes nothing; without coordinators no timeline is read
# and the same fixture is promoted, reviewed and merge-checked as before.
# X0.3b: logins compare case-insensitively; a raw multi-page timeline with
# mixed event types is parsed by fleet itself (the stub refuses --jq); a held
# package's PR on a verify target is neither posted, stamped nor retitled.
set -uo pipefail
cd "$(dirname "$0")"
. ./lib.sh

HERE=$(pwd -P)
FLEET="$(cd .. && pwd -P)/bin/fleet.js"
PLUGIN="$(cd ../../agentic-work-packages && pwd -P)"
assert_file "$FLEET" "fleet.js exists"

TMP=$(mktemp -d)
VPID=""
trap '[ -n "$VPID" ] && kill "$VPID" 2>/dev/null; rm -rf "$TMP"' EXIT
TMP=$(cd "$TMP" && pwd -P)

# --- a real remote with a review policy, an integration branch and two package branches
git init -q --bare -b main "$TMP/api.git"
git clone -q "$TMP/api.git" "$TMP/api" 2>/dev/null
git -C "$TMP/api" checkout -q -b main 2>/dev/null || true
git -C "$TMP/api" config user.email f@example.invalid; git -C "$TMP/api" config user.name fixture
printf '# api\n' > "$TMP/api/README.md"
git -C "$TMP/api" add -A && git -C "$TMP/api" commit -qm init && git -C "$TMP/api" push -q -u origin main
fixture_standards "$TMP/api"
printf '{"version": 1, "checks": [{"name": "test", "command": "true"}], "rules": [], "review": {"passes": 1}}\n' > "$TMP/api/.claude/standards.json"
git -C "$TMP/api" commit -qam "fixture: review policy" && git -C "$TMP/api" push -q origin main
git -C "$TMP/api" push -q origin main:integ
for b in t1-4 t1-5; do
  git -C "$TMP/api" checkout -q -b "feat/$b" main && printf '%s\n' "$b" > "$TMP/api/$b.txt" && git -C "$TMP/api" add -A && git -C "$TMP/api" commit -qm "$b" && git -C "$TMP/api" push -q origin "feat/$b"
done
git -C "$TMP/api" checkout -q main
H4=$(git -C "$TMP/api" rev-parse feat/t1-4)
H5=$(git -C "$TMP/api" rev-parse feat/t1-5)

# --- stubs -------------------------------------------------------------------
STUB="$TMP/stub"; RLOG="$TMP/reviewer-log"; mkdir -p "$STUB" "$TMP/gh" "$TMP/claude-log"
cp "$HERE/stubs/gh.js" "$STUB/gh.js"
printf '#!/usr/bin/env bash\nexec node "%s/gh.js" "$@"\n' "$STUB" > "$STUB/gh"; chmod +x "$STUB/gh"
cp "$HERE/stubs/claude.sh" "$STUB/claude"; chmod +x "$STUB/claude"
cp "$HERE/stubs/reviewer.sh" "$STUB/reviewer"; chmod +x "$STUB/reviewer"
export GH_STUB_DIR="$TMP/gh" GH_STUB_REMOTE="$TMP/api.git" CLAUDE_STUB_LOG="$TMP/claude-log" CLAUDE_STUB_TARGET="acme/api"
export GH_BIN="$STUB/gh" CLAUDE_BIN="$STUB/claude" REVIEWER_STUB_LOG="$RLOG"
export CLAUDE_CONFIG_FILE="$TMP/claude.json"
node -e "require('fs').writeFileSync('$TMP/claude.json', JSON.stringify({projects:{['$TMP/api']:{hasTrustDialogAccepted:true}}}))"
unset CLAUDECODE FLEET_STUB_LOGIN

scope_body() { # branch
  printf '**Part of** #1 · **Phase 0 · x** · **Repo:** `acme/api`\n\n## Goal\nx\n\n### SCOPE.json\n```json\n{"feature":"f","branch":"%s","allowedPaths":["src/**"],"forbiddenPaths":[],"dependsOn":[],"execution":{"model":"default","pattern":"solo"}}\n```\n' "$1"
}

# Five packages:
#   #10 T1.1  queued, worker:a applied by jack            -> flagged
#   #11 T1.2  agent-ready applied by jack, no cell:*      -> flagged, not promoted
#   #12 T1.3  agent-ready by jack, then by coordinator    -> the latest wins: promoted
#   #13 T1.4  cell:active, worker:a by jack, open PR #200 with no stamp
#   #14 T1.5  cell:active, worker:a by jack, open PR #201 stamped: awaits a reviewer
# reset [timeline-override-json]: fresh tracker, PRs, timeline and fleet state.
reset() {
  rm -rf "$TMP/state" "$TMP/worktrees" "$RLOG"; mkdir -p "$RLOG"
  git -C "$TMP/api" worktree prune   # the removed worktrees' registrations, or the next add refuses
  # A launch pushes its package branch; the next scenario starts without it.
  for b in feat/t1-1 feat/t1-2 feat/t1-3; do
    git --git-dir "$TMP/api.git" update-ref -d "refs/heads/$b" 2>/dev/null
    git -C "$TMP/api" branch -q -D "$b" 2>/dev/null
  done
  node - "$TMP/gh" "$H4" "$H5" "${1:-{\}}" $(for k in 1 2 3 4 5; do printf '%s ' "$(scope_body "feat/t1-$k" | base64 -w0)"; done) <<'JS'
const fs = require('fs'); const [dir, h4, h5, over, ...bodies] = process.argv.slice(2);
const body = k => Buffer.from(bodies[k - 1], 'base64').toString();
const pkg = (k, labels) => ({ number: 9 + k, title: `T1.${k} Package ${k}`, body: body(k), state: 'OPEN', labels });
fs.writeFileSync(`${dir}/issues.json`, JSON.stringify([
  { number: 1, title: 'Epic: program T', body: '', state: 'OPEN', labels: ['epic'] },
  pkg(1, ['agent-ready', 'cell:queued', 'worker:a']),
  pkg(2, ['agent-ready']),
  pkg(3, ['agent-ready']),
  pkg(4, ['agent-ready', 'cell:active', 'worker:a']),
  pkg(5, ['agent-ready', 'cell:active', 'worker:a']),
], null, 2));
const pr = (n, issue, branch, head) => ({ number: n, title: `[READY]: T1.${issue - 9} done`, body: `Closes #${issue}`, state: 'OPEN',
  baseRefName: 'integ', headRefName: branch, headRefOid: head, mergeable: 'MERGEABLE', isDraft: false, url: `https://example.invalid/pr/${n}`, repo: 'acme/api' });
fs.writeFileSync(`${dir}/prs.json`, JSON.stringify([pr(200, 13, 'feat/t1-4', h4), pr(201, 14, 'feat/t1-5', h5)], null, 2));
fs.writeFileSync(`${dir}/comments.json`, JSON.stringify({ 'acme/api#201': [{ id: 1, body: `VERIFIED: test @ ${h5}\n\ntest: true\nok`, created_at: '2026-11-16T00:00:00Z' }] }, null, 2));
fs.writeFileSync(`${dir}/checks.json`, JSON.stringify({ 'acme/api#201': [{ name: 'test', state: 'SUCCESS', bucket: 'pass' }] }, null, 2));
const ev = (label, login) => ({ event: 'labeled', label: { name: label }, actor: { login } });
const by = (labels, login) => labels.map(l => ev(l, login));
const timeline = {
  10: [...by(['agent-ready', 'cell:queued'], 'coordinator'), ev('worker:a', 'jack')],
  11: [ev('agent-ready', 'jack')],
  12: [ev('agent-ready', 'jack'), { event: 'unlabeled', label: { name: 'agent-ready' }, actor: { login: 'coordinator' } }, ev('agent-ready', 'coordinator')],
  13: [...by(['agent-ready', 'cell:active'], 'coordinator'), ev('worker:a', 'jack')],
  14: [...by(['agent-ready', 'cell:active'], 'coordinator'), ev('worker:a', 'jack')],
  ...JSON.parse(over),
};
fs.writeFileSync(`${dir}/timeline.json`, JSON.stringify(timeline, null, 2));
fs.writeFileSync(`${dir}/labels.json`, '{}'); fs.writeFileSync(`${dir}/writes.log`, ''); fs.writeFileSync(`${dir}/reads.log`, '');
JS
}

write_config() { # extra-json-fields
  cat > "$TMP/fleet.config.json" <<JSON
{
  "repo": "acme/host", "epic": 1,
  "targets": [{ "repo": "acme/api", "localPath": "$TMP/api", "defaultBranch": "main", "integrationBranch": "integ", "autoMerge": true }],
  "workers": { "a": { "mode": "local" } },
  "wipCap": 1, "worktreesDir": "$TMP/worktrees", "stateDir": "$TMP/state",
  "pluginRoot": "$PLUGIN", "maxEscalations": 1, "noMovementLimit": 99, "sessionTimeoutMinutes": 5,
  "reviewers": [{ "name": "stub-a", "argv": ["$STUB/reviewer", "{prompt}", "{worktree}", "{out}"] }]
  $1
}
JSON
}
fleet() { node "$FLEET" "$@" --config "$TMP/fleet.config.json"; }
cycle() { OUT=$(fleet cycle "$@" --json 2>"$TMP/cycle.err"); EXIT=$?; }
jq_out() { printf '%s' "$OUT" | node -e "const r=JSON.parse(require('fs').readFileSync(0,'utf8')); console.log($1)"; }
alarm_detail() { jq_out "r.alarms.filter(a=>a.code==='$1').map(a=>a.detail).join(' | ')"; }
alarm_issues() { jq_out "r.alarms.filter(a=>a.code==='$1').map(a=>a.issue).sort().join(',')"; }
promoted() { jq_out "r.promoted.map(e=>e.number).sort().join(',')"; }
launched() { jq_out "r.launched.map(e=>e.issue).sort().join(',')"; }
held_why() { jq_out "r.held.filter(h=>h.number===$1).map(h=>h.why).join(' | ')"; }
assign_row() { jq_out "(r.assigned.concat(r.assignHeld||[])).filter(x=>x.number===$1).map(x=>x.action+': '+x.why).join(' | ')"; }
review_prs() { jq_out "[...new Set(r.review.map(x=>x.pr))].sort().join(',')"; }
merge_prs() { jq_out "[...new Set(r.merge.map(x=>x.pr))].sort().join(',')"; }
timeline_reads() { grep -c '^timeline ' "$TMP/gh/reads.log" || true; }
user_reads() { grep -c '^user$' "$TMP/gh/reads.log" || true; }
edits_of() { grep "^edit $1 " "$TMP/gh/writes.log" | tr '\n' '|'; }

# --- A. without coordinators: no timeline is read, nothing is flagged ----------
write_config ""
reset
cycle --apply
assert_eq "0" "$(timeline_reads)" "A: no coordinators: no timeline is read"
assert_eq "0" "$(user_reads)" "A: no coordinators: fleet's login is not read"
assert_eq "" "$(alarm_detail label-foreign-actor)" "A: no label-foreign-actor alarm"
assert_eq "11,12" "$(promoted)" "A: both agent-ready packages are promoted"
assert_contains ",$(merge_prs)," ",200," "A: the merge stage judges #13's PR #200"
assert_contains ",$(review_prs)," ",201," "A: the review stage acts on #14's PR #201"

# --- B. coordinators set: foreign labels raise an alarm and hold the package ---
write_config ', "coordinators": ["coordinator"]'
reset
cycle --apply
assert_eq "1" "$(user_reads)" "B: fleet's own login is read once"
assert_eq "10,11,13,14" "$(alarm_issues label-foreign-actor)" "B: one label-foreign-actor alarm each for #10, #13, #14 (worker:a) and #11 (agent-ready), none for #12"
D=$(alarm_detail label-foreign-actor)
assert_contains "$D" "T1.1 #10: worker:a applied by jack, not a coordinator (coordinator); fleet will not promote, assign, launch, re-dispatch, review or merge it" "B: the alarm names the package, the label, the actor and the coordinators"
assert_contains "$(jq_out "r.alarms.filter(a=>a.code==='label-foreign-actor'&&a.issue===11).map(a=>a.detail).join()")" "T1.2 #11: agent-ready applied by jack" "B: #11's agent-ready from jack is flagged"
assert_eq "" "$(edits_of 10)" "B: no label is written on #10 (no worker: write)"
assert_not_contains ",$(launched)," ",10," "B: #10 is not launched"
assert_eq "" "$(edits_of 11)" "B: #11 is not labeled cell:queued"
assert_not_contains ",$(promoted)," ",11," "B: #11 is not promoted"
assert_eq "12" "$(promoted)" "B: #12, re-labeled agent-ready by a coordinator after jack, is promoted: the latest event wins"
assert_contains "$(edits_of 12)" "+cell:queued" "B: #12 is labeled cell:queued"
assert_contains "$(assign_row 12)" "WIP cap reached (1/1 in flight)" "B: flagged cell:active #13 still counts toward wipCap 1, so #12 waits"
assert_not_contains ",$(merge_prs)," ",200," "B: #13's PR #200 is not judged for merge"
assert_not_contains ",$(merge_prs)," ",201," "B: #14's PR #201 is not judged for merge"
assert_not_contains ",$(review_prs)," ",201," "B: #14's PR #201 is not reviewed"
assert_eq "" "$(ls "$RLOG")" "B: no reviewer is launched"
assert_eq "" "$(grep -E '^merge' "$TMP/gh/writes.log")" "B: nothing is merged"
assert_eq "alarm" "$(jq_out r.outcome)" "B: a flagged package makes the cycle an alarm"

# Control for the wipCap case: with #13's labels from a coordinator, nothing is
# in flight and #12 is assigned, so the hold above was #13's count.
reset '{"13":[{"event":"labeled","label":{"name":"agent-ready"},"actor":{"login":"coordinator"}},{"event":"labeled","label":{"name":"cell:active"},"actor":{"login":"coordinator"}},{"event":"labeled","label":{"name":"worker:a"},"actor":{"login":"coordinator"}}],"14":[{"event":"labeled","label":{"name":"agent-ready"},"actor":{"login":"coordinator"}},{"event":"labeled","label":{"name":"cell:active"},"actor":{"login":"coordinator"}},{"event":"labeled","label":{"name":"worker:a"},"actor":{"login":"coordinator"}}]}'
write_config ', "coordinators": ["coordinator"], "wipCap": 2'
cycle --apply
assert_eq "10,11" "$(alarm_issues label-foreign-actor)" "B': with #13 and #14 trusted, only #10 and #11 are flagged"
assert_contains ",$(merge_prs)," ",200," "B': trusted #13's PR is judged for merge"
assert_contains ",$(review_prs)," ",201," "B': trusted #14's PR is reviewed"
assert_contains "$(assign_row 12)" "assign" "B': #12 is assigned once #13 is the only package in flight under wipCap 2"
assert_eq "12" "$(launched)" "B': #12 is launched"

# --- B''. a held package is not re-dispatched --------------------------------
# #12's worker exits silent (the claude stub's default); before the next cycle
# jack re-applies its worker:a, so the escalation is held, not launched.
wait_for_file "$TMP/state/logs/12-1.exit" 30 && _pass "B'': attempt 1 of #12 exited" || _fail "B'': attempt 1 of #12 exited" "no exit file 12-1"
FLEET_STUB_LOGIN=jack "$STUB/gh" issue edit 12 --repo acme/host --remove-label worker:a >/dev/null
FLEET_STUB_LOGIN=jack "$STUB/gh" issue edit 12 --repo acme/host --add-label worker:a >/dev/null
cycle --apply
assert_contains "$(jq_out "r.alarms.filter(a=>a.code==='label-foreign-actor'&&a.issue===12).map(a=>a.detail).join()")" "T1.3 #12: worker:a applied by jack" "B'': #12's worker:a from jack is flagged"
assert_eq "label-foreign-actor" "$(held_why 12)" "B'': the re-dispatch is recorded in held with why label-foreign-actor"
assert_eq "retry" "$(node -e "console.log(require('$TMP/state/state.json').sessions[12].status)")" "B'': the session is kept for retry"
assert_not_contains ",$(launched)," ",12," "B'': #12 is not re-dispatched"
assert_eq "" "$(ls "$TMP/claude-log" | grep '^T1\.3\.2\.')" "B'': no second attempt of T1.3 is started"

# --- B'''. a reviewer already running when the package is flagged posts nothing --
TRUST1314='{"13":[{"event":"labeled","label":{"name":"agent-ready"},"actor":{"login":"coordinator"}},{"event":"labeled","label":{"name":"cell:active"},"actor":{"login":"coordinator"}},{"event":"labeled","label":{"name":"worker:a"},"actor":{"login":"coordinator"}}],"14":[{"event":"labeled","label":{"name":"agent-ready"},"actor":{"login":"coordinator"}},{"event":"labeled","label":{"name":"cell:active"},"actor":{"login":"coordinator"}},{"event":"labeled","label":{"name":"worker:a"},"actor":{"login":"coordinator"}}]}'
reset "$TRUST1314"
rm -f "$TMP/gate"
export REVIEWER_STUB_VERDICT=sleep REVIEWER_STUB_GATE="$TMP/gate"
cycle --apply
assert_contains ",$(review_prs)," ",201," "B''': a reviewer starts on trusted #14's PR #201"
wait_for_file "$RLOG/201.1.argv" 30 && _pass "B''': the reviewer is running" || _fail "B''': the reviewer is running" "no argv file"
FLEET_STUB_LOGIN=jack "$STUB/gh" issue edit 14 --repo acme/host --remove-label worker:a >/dev/null
FLEET_STUB_LOGIN=jack "$STUB/gh" issue edit 14 --repo acme/host --add-label worker:a >/dev/null
touch "$TMP/gate"
EXITF=$(node -e "console.log(require('$TMP/state/state.json').review['acme/api'].inFlight[0].exitPath)")
wait_for_file "$EXITF" 30 && _pass "B''': the reviewer exited with a pass verdict" || _fail "B''': the reviewer exited with a pass verdict" "no $EXITF"
cycle --apply
stamps201() { node -e "console.log((require('$TMP/gh/comments.json')['acme/api#201']||[]).filter(c=>/^REVIEWED/.test(c.body)).length)"; }
assert_eq "0" "$(stamps201)" "B''': flagged #14's finished review posts no REVIEWED stamp"
assert_contains "$(jq_out "r.review.filter(x=>x.pr===201).map(x=>x.action).join()")" "held" "B''': the report names the held review"
assert_eq "1" "$(node -e "console.log(require('$TMP/state/state.json').review['acme/api'].inFlight.length)")" "B''': the in-flight record is kept"
"$STUB/gh" issue edit 14 --repo acme/host --remove-label worker:a >/dev/null
"$STUB/gh" issue edit 14 --repo acme/host --add-label worker:a >/dev/null
cycle --apply
assert_eq "1" "$(stamps201)" "B''': once a coordinator re-applies worker:a, the held verdict is stamped"
unset REVIEWER_STUB_VERDICT REVIEWER_STUB_GATE

# --- C. a failed timeline read holds the package -------------------------------
write_config ', "coordinators": ["coordinator"]'
reset '{"12":"fail"}'
cycle --apply
assert_eq "12" "$(alarm_issues label-actors-failed)" "C: label-actors-failed for #12"
assert_contains "$(alarm_detail label-actors-failed)" "T1.3 #12" "C: the alarm names the package"
assert_not_contains ",$(promoted)," ",12," "C: #12 is not promoted: an unread provenance is not trusted"
assert_eq "" "$(edits_of 12)" "C: no label is written on #12"

# --- D. coordinators without fleet's own login: config-invalid -----------------
write_config ', "coordinators": ["someone-else"]'
reset
cycle --apply
assert_eq "64" "$EXIT" "D: the cycle exits 64 (usage)"
assert_contains "$(alarm_detail config-invalid)" "coordinator" "D: config-invalid names fleet's login"
assert_contains "$(alarm_detail config-invalid)" "coordinators" "D: config-invalid names the field"
assert_eq "" "$(promoted)" "D: nothing is promoted"
assert_eq "" "$(grep '+cell:queued' "$TMP/gh/writes.log")" "D: no cell:queued is written"
assert_eq "0" "$(timeline_reads)" "D: no timeline is read"

# --- E. the stub's own label writes are recorded as the stub's login -----------
FLEET_STUB_LOGIN=octo "$STUB/gh" issue edit 11 --repo acme/host --add-label cell:blocked >/dev/null
assert_eq '[{"event":"labeled","label":{"name":"cell:blocked"},"actor":{"login":"octo"}}]' "$(node -e "console.log(JSON.stringify(require('$TMP/gh/timeline.json')['11'].slice(-1)))")" "E: a label written through the stub is a labeled event by FLEET_STUB_LOGIN"
"$STUB/gh" issue edit 11 --repo acme/host --add-label cell:contract-change >/dev/null
assert_eq '"coordinator"' "$(node -e "console.log(JSON.stringify(require('$TMP/gh/timeline.json')['11'].slice(-1)[0].actor.login))")" "E: FLEET_STUB_LOGIN defaults to coordinator"

# --- F. logins compare case-insensitively (X0.3b) -------------------------------
# coordinators ["Octo"], gh runs as octo, #12's agent-ready applied by OCTO.
write_config ', "coordinators": ["Octo"]'
reset '{"12":[{"event":"labeled","label":{"name":"agent-ready"},"actor":{"login":"OCTO"}}]}'
FLEET_STUB_LOGIN=octo cycle --apply
assert_not_contains "$(jq_out "r.alarms.map(a=>a.code).join(' ')")" "config-invalid" "F: coordinators [Octo] with gh login octo: no config-invalid"
assert_not_contains ",$(alarm_issues label-foreign-actor)," ",12," "F: #12's agent-ready by OCTO is trusted"
assert_contains ",$(promoted)," ",12," "F: #12 is promoted"

# --- G. a multi-page timeline with mixed event types (X0.3b) --------------------
# The stub prints the raw timeline two events a page, as `gh api --paginate`
# does: `[..][..][..]`. Only `labeled` events count, the latest per label.
write_config ', "coordinators": ["coordinator"]'
reset '{
  "11":[{"event":"labeled","label":{"name":"agent-ready"},"actor":{"login":"coordinator"}},
        {"event":"commented","actor":{"login":"coordinator"},"body":"queued"},
        {"event":"cross-referenced","actor":{"login":"coordinator"},"source":{"type":"issue","issue":{"number":12}}},
        {"event":"labeled","label":{"name":"agent-ready"},"actor":{"login":"jack"}},
        {"event":"commented","actor":{"login":"coordinator"},"body":"hm"}],
  "12":[{"event":"labeled","label":{"name":"agent-ready"},"actor":{"login":"jack"}},
        {"event":"commented","actor":{"login":"jack"},"body":"mine"},
        {"event":"cross-referenced","actor":{"login":"jack"},"source":{"type":"issue","issue":{"number":11}}},
        {"event":"unlabeled","label":{"name":"agent-ready"},"actor":{"login":"coordinator"}},
        {"event":"labeled","label":{"name":"agent-ready"},"actor":{"login":"coordinator"}}]
}'
RAW=$(GH_STUB_TIMELINE_PAGE=2 "$STUB/gh" api repos/acme/host/issues/12/timeline --paginate)
assert_eq "3" "$(printf '%s' "$RAW" | grep -o '\]\[' | wc -l | tr -d ' ' | awk '{print $1+1}')" "G: the stub prints #12's timeline as three concatenated pages"
assert_contains "$(GH_STUB_TIMELINE_PAGE=2 "$STUB/gh" api repos/acme/host/issues/12/timeline --paginate --jq '.[]' 2>&1)" "--jq on the timeline is not emulated" "G: the stub refuses a --jq filter on the timeline"
# The page splitter itself: brackets and quotes inside strings, whitespace
# between pages, and text that is not a page sequence.
TL="$(cd .. && pwd -P)/src/tracker.js"
tl() { node -e "const {timelineEvents}=require('$TL'); try{console.log(JSON.stringify(timelineEvents(process.argv[1])))}catch(e){console.log('throws: '+e.message)}" "$1"; }
assert_eq '[{"body":"a ] [ \" }"},{"n":2}]' "$(tl '[{"body":"a ] [ \" }"}]
 [{"n":2}]')" "G: a bracket or escaped quote inside a string does not split a page; whitespace between pages is skipped"
assert_eq '[]' "$(tl '[]')" "G: an empty timeline is one empty page"
assert_contains "$(tl '[{"n":1}][{"n":2}')" "throws: the last page is cut off" "G: a cut-off last page throws"
assert_contains "$(tl '{"message":"Not Found"}')" "throws: a page is not a JSON array" "G: an object where a page should be throws"
: > "$TMP/gh/reads.log"
GH_STUB_TIMELINE_PAGE=2 cycle --apply
assert_eq "" "$(alarm_issues label-actors-failed)" "G: every timeline parses"
assert_contains "$(jq_out "r.alarms.filter(a=>a.code==='label-foreign-actor'&&a.issue===11).map(a=>a.detail).join()")" "T1.2 #11: agent-ready applied by jack" "G: #11's latest agent-ready (jack, page 2) is judged, not the coordinator's on page 1"
assert_not_contains ",$(alarm_issues label-foreign-actor)," ",12," "G: #12's latest agent-ready (coordinator, page 3) wins over jack's on page 1"
assert_eq "12" "$(promoted)" "G: #12 is promoted, #11 is not"

# G'. An `unlabeled` event is not a label write (X0.3c): a coordinator labeled
# #11 agent-ready, jack unlabeled it, then a coordinator labeled worker:a. The
# latest labeled agent-ready is the coordinator's, so #11 stays trusted. A
# parser that counted jack's unlabeled as labeled would flag #11 here.
UNLABELED11='{
  "11":[{"event":"labeled","label":{"name":"agent-ready"},"actor":{"login":"coordinator"}},
        {"event":"unlabeled","label":{"name":"agent-ready"},"actor":{"login":"jack"}},
        {"event":"labeled","label":{"name":"worker:a"},"actor":{"login":"coordinator"}}]
}'
reset "$UNLABELED11"
GH_STUB_TIMELINE_PAGE=2 cycle --apply
assert_eq "" "$(alarm_issues label-actors-failed)" "G': every timeline parses"
assert_not_contains ",$(alarm_issues label-foreign-actor)," ",11," "G': jack's unlabeled agent-ready on #11 is not a label write: #11 is not flagged"
assert_contains ",$(promoted)," ",11," "G': #11 is promoted"
# The fixture discriminates: a copy of fleet whose tracker.js counts
# `unlabeled` as `labeled` flags #11 on the same fixture.
MUT="$TMP/fleet-mutant"; cp -R "$(cd .. && pwd -P)" "$MUT"
node -e '
const fs = require("fs"), f = process.argv[1], s = fs.readFileSync(f, "utf8");
const from = "e.event !== \x27labeled\x27 ||";
if (!s.includes(from)) { console.log("anchor-missing"); process.exit(0); }
fs.writeFileSync(f, s.replace(from, "(e.event !== \x27labeled\x27 && e.event !== \x27unlabeled\x27) ||"));
console.log("mutated");
' "$MUT/src/tracker.js" > "$TMP/mutant.out"
assert_eq "mutated" "$(cat "$TMP/mutant.out")" "G': the mutant's tracker.js counts unlabeled as labeled"
reset "$UNLABELED11"
OUT=$(GH_STUB_TIMELINE_PAGE=2 node "$MUT/bin/fleet.js" cycle --apply --json --config "$TMP/fleet.config.json" 2>"$TMP/cycle.err")
assert_contains "$(jq_out "r.alarms.filter(a=>a.code==='label-foreign-actor'&&a.issue===11).map(a=>a.detail).join()")" "T1.2 #11: agent-ready applied by jack" "G': the mutant flags #11 on jack's unlabeled, so G' fails against it"
assert_not_contains ",$(promoted)," ",11," "G': the mutant does not promote #11"

# --- H. verify skips held packages (X0.3b) ----------------------------------------
PORT=$(node -e "const s=require('net').createServer().listen(0,'127.0.0.1',()=>{console.log(s.address().port);s.close()})")
VDIR="$TMP/verifier"; mkdir -p "$VDIR"
export VERIFIER_STUB_DIR="$VDIR" VERIFIER_STUB_PORT="$PORT"
printf '{}' > "$VDIR/script.json"; : > "$VDIR/requests.log"
node "$HERE/stubs/verifier.js" & VPID=$!
i=0; until [ -f "$VDIR/ready" ] || [ $i -ge 40 ]; do sleep 0.25; i=$((i + 1)); done
assert_file "$VDIR/ready" "H: the verifier stub listens on 127.0.0.1:$PORT"
vscript() { node -e "const f='$VDIR/script.json',fs=require('fs');const s=JSON.parse(fs.readFileSync(f,'utf8'));s.results=s.results||{};$1;fs.writeFileSync(f,JSON.stringify(s,null,2))"; }
posts() { grep -c ' POST ' "$VDIR/requests.log" || true; }
title_of() { node -e "console.log(require('$TMP/gh/prs.json').find(x=>x.number===$1).title)"; }
verified_on() { node -e "console.log((require('$TMP/gh/comments.json')['acme/api#$1']||[]).filter(c=>/^VERIFIED: lab-impacted @/.test(c.body)).length)"; }
inflight_pr() { node -e "const v=(require('$TMP/state/state.json').verify||{})['acme/api']||{}; console.log(v.inFlight?v.inFlight.pr:'none')"; }
# #13's PR #200 is [VERIFY]: without a stamp (the verifier's queue); #14's PR
# #201 is [VERIFY]: with a stamp at its head (to be retitled [READY]:).
to_verify() { node -e "const f='$TMP/gh/prs.json',fs=require('fs');const a=JSON.parse(fs.readFileSync(f,'utf8'));for(const p of a)p.title=p.title.replace(/^\[READY\]:/,'[VERIFY]:');fs.writeFileSync(f,JSON.stringify(a,null,2))"; }
write_config_verify() {
  cat > "$TMP/fleet.config.json" <<JSON
{
  "repo": "acme/host", "epic": 1,
  "targets": [{ "repo": "acme/api", "localPath": "$TMP/api", "defaultBranch": "main", "integrationBranch": "integ",
    "ci": { "gate": "external", "verifiedBy": "true" },
    "verify": { "kind": "lab-runner", "url": "http://127.0.0.1:$PORT", "suite": "impacted_v2" } }],
  "workers": { "a": { "mode": "local" } },
  "wipCap": 2, "worktreesDir": "$TMP/worktrees", "stateDir": "$TMP/state",
  "pluginRoot": "$PLUGIN", "maxEscalations": 1, "noMovementLimit": 99, "sessionTimeoutMinutes": 5,
  "reviewers": [{ "name": "stub-a", "argv": ["$STUB/reviewer", "{prompt}", "{worktree}", "{out}"] }],
  "coordinators": ["coordinator"]
}
JSON
}
write_config_verify

# H. #13 and #14 flagged (worker:a by jack): nothing posted, nothing retitled.
reset; to_verify
cycle --apply
assert_eq "10,11,13,14" "$(alarm_issues label-foreign-actor)" "H: #13 and #14 are flagged"
assert_eq "0" "$(posts)" "H: flagged #13's PR #200 is not posted to the verifier"
assert_eq "" "$(grep '^title ' "$TMP/gh/writes.log")" "H: no PR is retitled"
assert_eq "[VERIFY]: T1.5 done" "$(title_of 201)" "H: flagged #14's stamped PR #201 stays [VERIFY]:"

# H'. Control: the same fixture with #13 and #14 trusted posts #200 and retitles #201.
reset "$TRUST1314"; to_verify; : > "$VDIR/requests.log"
cycle --apply
assert_eq "1" "$(posts)" "H': trusted #13's PR #200 is posted to the verifier"
assert_contains "$(grep ' POST ' "$VDIR/requests.log")" "pr=200" "H': the POST is for PR #200"
assert_eq "[READY]: T1.5 done" "$(title_of 201)" "H': trusted #14's stamped PR #201 is retitled [READY]:"
assert_eq "200" "$(inflight_pr)" "H': the run for #200 is in flight"

# H''. #13 flagged while its run is in flight: the finished run is neither
# stamped nor commented; the record is kept and judged once a coordinator relabels.
FLEET_STUB_LOGIN=jack "$STUB/gh" issue edit 13 --repo acme/host --remove-label worker:a >/dev/null
FLEET_STUB_LOGIN=jack "$STUB/gh" issue edit 13 --repo acme/host --add-label worker:a >/dev/null
vscript "s.results['200']={finished:true,exitCode:0,reverted:true,tests:[]}"
# A push to trusted #14's PR #201 voids its stamp: the held run on the same
# target does not stop #201 going back to [VERIFY]:.
node -e "const f='$TMP/gh/prs.json',fs=require('fs');const a=JSON.parse(fs.readFileSync(f,'utf8'));a.find(x=>x.number===201).headRefOid='$(printf '%040d' 1)';fs.writeFileSync(f,JSON.stringify(a,null,2))"
: > "$VDIR/requests.log"
cycle --apply
assert_contains ",$(alarm_issues label-foreign-actor)," ",13," "H'': #13 is flagged"
assert_eq "[VERIFY]: T1.5 done" "$(title_of 201)" "H'': trusted #14's PR #201, its stamp voided by a push, is retitled [VERIFY]: while #13's run is held"
assert_eq "0" "$(posts)" "H'': nothing is posted in the held run's slot"
assert_eq "0" "$(verified_on 200)" "H'': flagged #13's finished run posts no VERIFIED stamp"
assert_eq "[VERIFY]: T1.4 done" "$(title_of 200)" "H'': flagged #13's PR #200 is not retitled"
assert_contains "$(jq_out "r.verify.filter(x=>x.pr===200).map(x=>x.action).join()")" "held" "H'': the report names the held run"
assert_eq "200" "$(inflight_pr)" "H'': the in-flight record is kept"
"$STUB/gh" issue edit 13 --repo acme/host --remove-label worker:a >/dev/null
"$STUB/gh" issue edit 13 --repo acme/host --add-label worker:a >/dev/null
cycle --apply
assert_eq "1" "$(verified_on 200)" "H'': once a coordinator re-applies worker:a, the held run is stamped"
assert_eq "[READY]: T1.4 done" "$(title_of 200)" "H'': and #200 is retitled [READY]:"

# H'''. A held package's run that did not revert the lab still latches the fleet:
# holding a package never hides a lab left dirty.
vscript "for (const k of Object.keys(s.results)) s.results[k].finished=true; s.results['201']=s.results['201']||{finished:true,exitCode:0,reverted:true,tests:[]}; s.results['200']={finished:false}"
reset "$TRUST1314"; to_verify
cycle --apply
assert_eq "200" "$(inflight_pr)" "H''': a run for trusted #13's PR #200 is in flight"
FLEET_STUB_LOGIN=jack "$STUB/gh" issue edit 13 --repo acme/host --remove-label worker:a >/dev/null
FLEET_STUB_LOGIN=jack "$STUB/gh" issue edit 13 --repo acme/host --add-label worker:a >/dev/null
vscript "s.results['200']={finished:true,exitCode:0,reverted:false,tests:[]}"
cycle --apply
assert_contains ",$(alarm_issues label-foreign-actor)," ",13," "H''': #13 is flagged"
assert_contains "$(jq_out "r.alarms.map(a=>a.code).join(' ')")" "verify-not-reverted" "H''': the not-reverted run raises verify-not-reverted"
assert_contains "$(node -e "console.log(JSON.stringify(require('$TMP/state/state.json').latched))")" "verify-not-reverted" "H''': the fleet is latched"
assert_eq "0" "$(verified_on 200)" "H''': #200 is not stamped"

# H''''. A held package's run whose status fetch fails raises verify-unreachable
# and keeps the record, as the stage does for an unheld run (X0.3c).
vscript "for (const k of Object.keys(s.results)) s.results[k].finished=true; s.results['200']={finished:false}"
reset "$TRUST1314"; to_verify
cycle --apply
assert_eq "200" "$(inflight_pr)" "H'''': a run for trusted #13's PR #200 is in flight"
FLEET_STUB_LOGIN=jack "$STUB/gh" issue edit 13 --repo acme/host --remove-label worker:a >/dev/null
FLEET_STUB_LOGIN=jack "$STUB/gh" issue edit 13 --repo acme/host --add-label worker:a >/dev/null
kill "$VPID" 2>/dev/null; wait "$VPID" 2>/dev/null; VPID=""
cycle --apply
assert_contains ",$(alarm_issues label-foreign-actor)," ",13," "H'''': #13 is flagged"
assert_eq "13" "$(alarm_issues verify-unreachable)" "H'''': the failed status fetch of held #13's run raises verify-unreachable on #13"
assert_contains "$(alarm_detail verify-unreachable)" "for PR #200 is kept" "H'''': the alarm detail has verify.js's shape: the run and PR, kept"
assert_eq "200" "$(inflight_pr)" "H'''': the in-flight record is kept"
assert_contains "$(jq_out "r.verify.filter(x=>x.pr===200).map(x=>x.action).join()")" "held" "H'''': the report still names the held run"

finish
