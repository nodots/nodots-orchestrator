#!/usr/bin/env bash
# RV gate: program R end to end through `fleet cycle`. A bare remote, the real
# sync-cells.sh, the gh and claude stubs and the reviewer stub
# (tests/stubs/reviewer.sh). The target's manifest sets review: {passes: 2} and
# two reviewers are configured, stub-a then stub-b.
#   1. Waiting: a verified PR is cell:awaiting-reviewer, not cell:awaiting-review.
#   2. Pass: one reviewer per cycle at the head; each pass posts REVIEWED with
#      the reviewer's name; after the second, cell:awaiting-review, and
#      scripts/check-stamp.js accepts the PR.
#   3. Push voids: a push after both stamps returns the PR to
#      cell:awaiting-reviewer, and check-stamp.js refuses it.
#   4. Fail: a second package's reviewer fails; the findings are commented, the
#      worker is re-dispatched at the same tier with reason review-failed: ...,
#      and the reviewer that failed is not run at that head again.
#   5. Distinct reviewers: the same reviewer stamping the same head twice counts
#      once, and the PR stays cell:awaiting-reviewer.
#   6. No policy: a target without `review` goes to cell:awaiting-review on its
#      VERIFIED stamp alone, and no reviewer runs.
#
# `gate-r-review.test.sh --break <1..6>` runs the suite against a copy of HEAD's
# tree, in its own temp directory, with the behavior scenario <n> checks broken;
# that scenario fails.
set -uo pipefail
RV_BREAK=""; [ "${1:-}" = "--break" ] && RV_BREAK="${2:?--break needs 1..6}"
cd "$(dirname "$0")"
. ./lib.sh

HERE=$(pwd -P)
ROOT="$(cd ../../.. && pwd -P)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
TMP=$(cd "$TMP" && pwd -P)

if [ -n "$RV_BREAK" ]; then
  A=plugins/agentic-work-packages/skills/agentic-work-packages/assets/scripts
  case "$RV_BREAK" in
    1) BF="$A/sync-cells.sh"; BE="s/return \[reviewMet\(policy, reviews\) \? 'cell:awaiting-review' : 'cell:awaiting-reviewer'/return ['cell:awaiting-review'/" ;;
    2) BF=plugins/fleet/src/review.js; BE='s/f\.pr, `REVIEWED: \$\{f\.reviewer\} @/f.pr, `REVIEWED: reviewer @/' ;;
    3) BF="$A/stamp.js"; BE='s/m\[2\] !== pr\.headSha \|\| seen/seen/' ;;
    4) BF=plugins/fleet/src/review.js; BE="s/      failAt\(f, 'failed', reason\);\n//" ;;
    5) BF="$A/stamp.js"; BE='s/ \|\| seen\.has\(m\[1\]\)\) continue;/) continue;/' ;;
    6) BF="$A/sync-cells.sh"; BE="s/if \(!policy\) return \['cell:awaiting-review'/if (!policy) return ['cell:awaiting-reviewer'/" ;;
    *) echo "--break $RV_BREAK: not 1..6" >&2; exit 2 ;;
  esac
  mkdir -p "$TMP/tree"; git -C "$ROOT" archive HEAD | tar -x -C "$TMP/tree"
  perl -0pi -e "$BE" "$TMP/tree/$BF"
  cmp -s "$ROOT/$BF" "$TMP/tree/$BF" && { echo "--break $RV_BREAK: the break did not apply to $BF" >&2; exit 2; }
  echo "  --break $RV_BREAK: $BF broken in $TMP/tree"
  ROOT="$TMP/tree"
fi
FLEET="$ROOT/plugins/fleet/bin/fleet.js"
PLUGIN="$ROOT/plugins/agentic-work-packages"
CHECK_STAMP="$ROOT/scripts/check-stamp.js"
assert_file "$FLEET" "fleet.js exists"
assert_file "$CHECK_STAMP" "check-stamp.js exists"

STUB="$TMP/stub"; mkdir -p "$STUB"
cp "$HERE/stubs/gh.js" "$STUB/gh.js"
printf '#!/usr/bin/env bash\nexec node "%s/gh.js" "$@"\n' "$STUB" > "$STUB/gh"; chmod +x "$STUB/gh"
cp "$HERE/stubs/claude.sh" "$STUB/claude"; chmod +x "$STUB/claude"
cp "$HERE/stubs/reviewer.sh" "$STUB/reviewer"; chmod +x "$STUB/reviewer"
export GH_BIN="$STUB/gh" CLAUDE_BIN="$STUB/claude" CLAUDE_STUB_TARGET="acme/api"
unset CLAUDECODE

# fixture <dir> <manifest> <packages>: a bare remote and clone under <dir>, the
# manifest committed on main, and <packages> queued packages T1.1.. (#10..) in
# the gh stub. Points the stubs and the helpers below at <dir>.
fixture() {
  F="$1"
  git init -q --bare -b main "$F/api.git"
  git clone -q "$F/api.git" "$F/api" 2>/dev/null
  git -C "$F/api" checkout -q -b main 2>/dev/null || true
  git -C "$F/api" config user.email f@example.invalid; git -C "$F/api" config user.name fixture
  printf '# api\n' > "$F/api/README.md"
  git -C "$F/api" add -A && git -C "$F/api" commit -qm init && git -C "$F/api" push -q -u origin main
  fixture_standards "$F/api"
  printf '%s\n' "$2" > "$F/api/.claude/standards.json"
  git -C "$F/api" commit -q --allow-empty -am "fixture: manifest" && git -C "$F/api" push -q origin main
  mkdir -p "$F/gh" "$F/claude-log"
  export GH_STUB_DIR="$F/gh" GH_STUB_REMOTE="$F/api.git" CLAUDE_STUB_LOG="$F/claude-log" REVIEWER_STUB_LOG="$F/reviewer-log"
  export CLAUDE_CONFIG_FILE="$F/claude.json"
  node -e "require('fs').writeFileSync('$F/claude.json', JSON.stringify({projects:{['$F/api']:{hasTrustDialogAccepted:true}}}))"
  local bodies=() k
  for k in $(seq 1 "$3"); do
    bodies+=("$(printf '**Part of** #1 · **Phase 0 · x** · **Repo:** `acme/api`\n\n## Goal\nGoal of T1.%s.\n\n### SCOPE.json\n```json\n{"feature":"f","branch":"feat/t1-%s","allowedPaths":["src/**"],"forbiddenPaths":[],"dependsOn":[],"execution":{"model":"default","pattern":"solo"}}\n```\n' "$k" "$k" | base64 -w0)")
  done
  node - "$F/gh" "${bodies[@]}" <<'JS'
const fs = require('fs'); const [dir, ...bodies] = process.argv.slice(2);
fs.writeFileSync(`${dir}/issues.json`, JSON.stringify([
  { number: 1, title: 'Epic: program T', body: '', state: 'OPEN', labels: ['epic'] },
  ...bodies.map((b, i) => ({ number: 10 + i, title: `T1.${i + 1} Package ${i + 1}`, body: Buffer.from(b, 'base64').toString(), state: 'OPEN', labels: ['agent-ready', 'cell:queued', 'worker:a'] })),
], null, 2));
for (const [f, v] of [['prs.json', '[]'], ['labels.json', '{}'], ['comments.json', '{}'], ['writes.log', '']]) fs.writeFileSync(`${dir}/${f}`, v);
JS
  cat > "$F/fleet.config.json" <<JSON
{
  "repo": "acme/host", "epic": 1,
  "targets": [{ "repo": "acme/api", "localPath": "$F/api", "defaultBranch": "main" }],
  "workers": { "a": { "mode": "local" } },
  "wipCap": 8, "worktreesDir": "$F/worktrees", "stateDir": "$F/state",
  "pluginRoot": "$PLUGIN", "maxEscalations": 2, "noMovementLimit": 20, "sessionTimeoutMinutes": 5,
  "reviewers": [
    { "name": "stub-a", "argv": ["$STUB/reviewer", "{prompt}", "{worktree}", "{out}"] },
    { "name": "stub-b", "argv": ["env", "-u", "REVIEWER_STUB_VERDICT_201", "$STUB/reviewer", "{prompt}", "{worktree}", "{out}"] }
  ]
}
JSON
  # Open one [READY] PR per package (#200..), each with a current VERIFIED stamp.
  for k in $(seq 1 "$3"); do
    export "CLAUDE_STUB_MODE_T1_$k=pr"
    fleet launch $((9 + k)) --apply >/dev/null 2>&1; wait_exit "$((9 + k))-1"
    export "CLAUDE_STUB_MODE_T1_$k=silent"
    verify_stamp $((199 + k))
  done
}

fleet() { node "$FLEET" "$@" --config "$F/fleet.config.json"; }
cycle() { OUT=$(fleet cycle --apply --json 2>"$F/cycle.err"); EXIT=$?; }
wait_exit() { local f="$F/state/logs/$1.exit" i=0; until [ -f "$f" ] || [ $i -ge 60 ]; do sleep 0.5; i=$((i + 1)); done; [ -f "$f" ]; }
st() { node -e "const s=require('$F/state/state.json'); const v=(s.review||{})['acme/api']||{}; console.log(JSON.stringify($1))"; }
pr_field() { node -e "const p=require('$F/gh/prs.json').find(x=>x.number===$1); console.log(p.$2)"; }
set_head() { node -e "const f='$F/gh/prs.json',fs=require('fs');const a=JSON.parse(fs.readFileSync(f,'utf8'));a.find(x=>x.number===$1).headRefOid='$2';fs.writeFileSync(f,JSON.stringify(a,null,2))"; }
add_comment() { node -e "const f='$F/gh/comments.json',fs=require('fs');const a=JSON.parse(fs.readFileSync(f,'utf8'));const k='acme/api#$1';a[k]=[...(a[k]||[]),{id:Date.now(),body:process.argv[1],created_at:new Date().toISOString()}];fs.writeFileSync(f,JSON.stringify(a,null,2))" "$2"; }
verify_stamp() { add_comment "$1" "VERIFIED: test @ $(pr_field "$1" headRefOid)

test: true
ok"; }
comments_on() { node -e "const c=require('$F/gh/comments.json')['acme/api#$1']||[]; process.stdout.write(c.map(x=>x.body).join('\n<<>>\n'))"; }
first_lines() { node -e "const c=require('$F/gh/comments.json')['acme/api#$1']||[]; console.log(c.map(x=>x.body.split('\n')[0]).join('|'))"; }
jq_out() { printf '%s' "$OUT" | node -e "const r=JSON.parse(require('fs').readFileSync(0,'utf8')); console.log($1)"; }
labels_of() { node -e "console.log(' '+(require('$F/gh/labels.json')[$1]||[]).join(' ')+' ')"; }
# runs_by <pr> <reviewer>: how many times the reviewer stub ran on the PR, as <reviewer>.
runs_by() { cat "$F/reviewer-log/$1".*.env 2>/dev/null | grep -c "^FLEET_REVIEWER=$2\$"; }
# check_stamp <pr>: scripts/check-stamp.js over the PR as CI collects it: title,
# head, comment bodies, and the base branch's manifest. Prints "exit=<n>" then its output.
check_stamp() {
  node -e "
    const p=require('$F/gh/prs.json').find(x=>x.number===$1);
    const c=(require('$F/gh/comments.json')['acme/api#$1']||[]).map(x=>x.body);
    const m=require('child_process').execFileSync('git',['--git-dir','$F/api.git','show','main:.claude/standards.json'],{encoding:'utf8'});
    require('fs').writeFileSync('$F/pr-$1.json', JSON.stringify({title:p.title,headSha:p.headRefOid,comments:c,manifest:m}));"
  local o; o=$(node "$CHECK_STAMP" "$F/pr-$1.json" 2>&1); echo "exit=$? $o"
}

# === fixture 1: review {passes: 2}, two packages =================================
mkdir -p "$TMP/r"
fixture "$TMP/r" '{"version": 1, "checks": [{"name": "test", "command": "true"}], "rules": [], "review": {"passes": 2}}' 2
assert_eq "[READY]: T1.1 done|[READY]: T1.2 done" "$(pr_field 200 title)|$(pr_field 201 title)" "setup: PRs #200 (T1.1) and #201 (T1.2)"
H200=$(pr_field 200 headRefOid); H201=$(pr_field 201 headRefOid)
export REVIEWER_STUB_VERDICT_201=fail   # stub-a fails #201; stub-b's argv unsets it, so stub-b passes there

# --- 1. waiting --------------------------------------------------------------------
cycle
assert_eq "0" "$EXIT" "cycle 1 exits 0"
assert_contains "$(labels_of 10)" " cell:awaiting-reviewer " "waiting: a verified PR under review {passes: 2} is cell:awaiting-reviewer"
assert_not_contains "$(labels_of 10)" " cell:awaiting-review " "waiting: not cell:awaiting-review"
assert_contains "$(labels_of 11)" " cell:awaiting-reviewer " "waiting: the second package too"
assert_contains "$(check_stamp 200)" "exit=1" "waiting: check-stamp.js refuses a PR with VERIFIED and no REVIEWED"

# --- 2. pass, reviewer one -----------------------------------------------------------
assert_eq "\"200:stub-a:$H200|201:stub-a:$H201\"" "$(st 'v.inFlight.map(x=>x.pr+":"+x.reviewer+":"+x.headSha).sort().join("|")')" "pass: one cycle launches one reviewer per PR, the first in config order, at the head"
wait_for_file "$F/state/review/api-200-stub-a-*/exit"
wait_for_file "$F/state/review/api-201-stub-a-*/exit"
assert_eq "1|0" "$(runs_by 200 stub-a)|$(runs_by 200 stub-b)" "pass: only stub-a has run on #200"
assert_contains "$(cat "$F/reviewer-log/200.1.env")" "head=$H200" "pass: the reviewer ran at the PR head"
cycle
assert_contains "$(first_lines 200)" "REVIEWED: stub-a @ $H200" "pass: stub-a's pass posts REVIEWED: stub-a @ <head>"
assert_eq "0" "$(st 'v.inFlight.length')" "pass: no second reviewer in the cycle that stamped (its sync predates the stamp)"

# --- 4. fail -------------------------------------------------------------------------
C201=$(comments_on 201)
assert_not_contains "$C201" "REVIEWED:" "fail: no stamp on #201"
assert_contains "$C201" "Review by stub-a failed at $H201" "fail: the failure is commented on the PR"
assert_contains "$C201" "src/x.txt:3 — the guard is inverted" "fail: the first finding, file and line, is commented"
assert_contains "$C201" "src/y.txt:9 — no test fails without the change" "fail: every finding is commented"
assert_eq "default|2" "$(jq_out "r.launched.filter(l=>l.issue===11).map(l=>l.tier+'|'+l.attempt).join()")" "fail: the worker is re-dispatched at the same tier"
assert_eq "review-failed: the guard is inverted|default" "$(node -e "const d=require('$F/state/state.json').dispatches['T1.2']; console.log(d[d.length-1].reason+'|'+d[d.length-1].tier)")" "fail: the re-dispatch reason is review-failed: <first claim>"
assert_eq "\"$H201\"" "$(st 'v.failed["201"]["stub-a"].headSha')" "fail: the failed head is recorded"
wait_exit "11-2"

# --- 5. distinct reviewers -------------------------------------------------------------
add_comment 200 "REVIEWED: stub-a @ $H200

Findings checked:
- src/x.txt:1 — the same reviewer again"
cycle
assert_contains "$(labels_of 10)" " cell:awaiting-reviewer " "distinct: stub-a stamped #200 twice, and it stays cell:awaiting-reviewer"
CS=$(check_stamp 200)
assert_contains "$CS" "exit=1" "distinct: check-stamp.js refuses two stamps from one reviewer against passes 2"
assert_contains "$CS" "REVIEWED stub-a @ $H200; the review policy needs 2 reviews, missing 1 review" "distinct: check-stamp.js counts stub-a once"

# --- 2. pass, reviewer two ---------------------------------------------------------------
assert_contains "$(st 'v.inFlight.filter(x=>x.pr===200).map(x=>x.reviewer+":"+x.headSha).join()')" "stub-b:$H200" "pass: the next cycle launches the second reviewer at the head"
wait_for_file "$F/reviewer-log/200.2.env"
assert_eq "1|1" "$(runs_by 200 stub-a)|$(runs_by 200 stub-b)" "pass: stub-a is not run again on #200; stub-b runs once"
wait_for_file "$F/state/review/api-200-stub-b-*/exit"
wait_for_file "$F/state/review/api-201-stub-b-*/exit"
cycle
assert_contains "$(first_lines 200)" "REVIEWED: stub-b @ $H200" "pass: stub-b's pass posts REVIEWED: stub-b @ <head>"
cycle
assert_contains "$(labels_of 10)" " cell:awaiting-review " "pass: after both passes the sync derives cell:awaiting-review"
assert_not_contains "$(labels_of 10)" " cell:awaiting-reviewer " "pass: no longer cell:awaiting-reviewer"
CS=$(check_stamp 200)
assert_contains "$CS" "exit=0" "pass: check-stamp.js accepts the PR"
assert_contains "$CS" "REVIEWED stub-a, stub-b @ $H200" "pass: check-stamp.js counts both reviewers"
assert_eq "1|1" "$(runs_by 200 stub-a)|$(runs_by 200 stub-b)" "pass: no reviewer runs on #200 once the policy is met"

# --- 4. fail: the reviewer that failed is not run at that head again ----------------------
cycle
assert_eq "$H201" "$(pr_field 201 headRefOid)" "fail: #201's head has not moved"
assert_eq "1" "$(runs_by 201 stub-a)" "fail: stub-a is not run again at the head it failed"
assert_contains "$(labels_of 11)" " cell:awaiting-reviewer " "fail: #201 never passes cell:awaiting-reviewer at the failed head"
assert_contains "$(jq_out "r.review.filter(x=>x.pr===201).map(x=>x.action+' '+x.detail).join()")" "held no reviewer left at ${H201:0:7}" "fail: #201 is held: every reviewer has stamped or failed at that head"
assert_contains "$(check_stamp 201)" "exit=1" "fail: check-stamp.js refuses #201"

# --- 3. push voids -----------------------------------------------------------------------
git -C "$F/worktrees/api-t1-1" -c user.name=stub -c user.email=stub@example.invalid commit -q --allow-empty -m "push after review" && git -C "$F/worktrees/api-t1-1" push -q origin HEAD
N200=$(git -C "$F/worktrees/api-t1-1" rev-parse HEAD)
set_head 200 "$N200"
CS=$(check_stamp 200)
assert_contains "$CS" "exit=1" "push voids: check-stamp.js refuses the PR at the new head"
assert_contains "$CS" "REVIEWED none @ $N200" "push voids: neither REVIEWED stamp counts at the new head"
verify_stamp 200   # the worker re-verifies the new head
cycle
assert_contains "$(labels_of 10)" " cell:awaiting-reviewer " "push voids: re-verified at the new head, #200 is cell:awaiting-reviewer again"
assert_not_contains "$(labels_of 10)" " cell:awaiting-review " "push voids: not cell:awaiting-review"
CS=$(check_stamp 200)
assert_contains "$CS" "exit=1" "push voids: check-stamp.js refuses it with a current VERIFIED stamp"
assert_contains "$CS" "missing 2 reviews" "push voids: both reviews are missing"

# === fixture 2: no review policy ============================================================
mkdir -p "$TMP/n"
fixture "$TMP/n" '{"version": 1, "checks": [{"name": "test", "command": "true"}], "rules": []}' 1
cycle
assert_eq "0" "$EXIT" "no policy: the cycle exits 0"
assert_contains "$(labels_of 10)" " cell:awaiting-review " "no policy: the VERIFIED stamp alone gives cell:awaiting-review"
assert_not_contains "$(labels_of 10)" " cell:awaiting-reviewer " "no policy: not cell:awaiting-reviewer"
assert_eq "0" "$(st 'v.inFlight ? v.inFlight.length : 0')" "no policy: no review in flight"
sleep 1
assert_eq "0" "$(compgen -G "$F/reviewer-log/*" | wc -l | tr -d ' ')" "no policy: no reviewer runs"
assert_eq "0" "$(jq_out "r.review.filter(x=>x.action==='launched').length")" "no policy: the report launches no reviewer"
CS=$(check_stamp 200)
assert_contains "$CS" "exit=0" "no policy: check-stamp.js accepts the PR on VERIFIED alone"
assert_not_contains "$CS" "REVIEWED" "no policy: check-stamp.js asks for no review"

finish
