#!/usr/bin/env bash
# Commit identity. Fleet's own commits on a package branch (the scope commit,
# and the re-cut of an adopted worktree's lane) carry the user.name and
# user.email configured in the target clone, as author and committer. A clone
# with no identity is refused identity-missing at launch, in the dry run and in
# the applied cycle, before any worktree exists; the alarm names the clone and
# the two git config commands that fix it. fleet doctor prints the identity per
# target, or the failure.
#
# The global and system git config are cut off for the whole script, so an
# identity on the machine running the suite cannot stand in for the clone's.
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

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
unset GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL EMAIL

# clone <name>: a bare remote and a clone with a pushed main that carries a
# standards manifest. The clone's identity is set; a case unsets it.
clone() {
  git init -q --bare -b main "$TMP/$1.git"
  git clone -q "$TMP/$1.git" "$TMP/$1" 2>/dev/null
  git -C "$TMP/$1" checkout -q -b main 2>/dev/null || true
  git -C "$TMP/$1" config user.email ada@example.invalid; git -C "$TMP/$1" config user.name "Ada Human"
  mkdir -p "$TMP/$1/src"
  printf '# api\n' > "$TMP/$1/README.md"
  printf 'x\n' > "$TMP/$1/src/index.js"
  git -C "$TMP/$1" add -A && git -C "$TMP/$1" commit -qm init
  fixture_standards "$TMP/$1" && git -C "$TMP/$1" push -q -u origin main
}
clone api

STUB="$TMP/stub"; mkdir -p "$STUB" "$TMP/gh"
cp "$HERE/stubs/gh.js" "$STUB/gh.js"
printf '#!/usr/bin/env bash\nexec node "%s/gh.js" "$@"\n' "$STUB" > "$STUB/gh"; chmod +x "$STUB/gh"
cp "$HERE/stubs/claude.sh" "$STUB/claude"; chmod +x "$STUB/claude"
export GH_STUB_DIR="$TMP/gh" CLAUDE_STUB_TARGET="acme/api"
export GH_BIN="$STUB/gh" CLAUDE_BIN="$STUB/claude"
export CLAUDE_CONFIG_FILE="$TMP/claude.json"
unset CLAUDECODE
printf '{}' > "$TMP/gh/ci.json"

# phase <n> <tag> <clone> [allowed glob]: one queued package T1.<n> (issue
# 10+<n>) on branch feat/t1-<n>-<tag> against <clone>, with fresh state and
# claude log.
phase() {
  N="$1"; P="$2"; C="$3"; ISSUE=$((10 + N)); ID="T1.$N"; BR="feat/t1-$N-$P"
  export GH_STUB_REMOTE="$TMP/$C.git"
  export CLAUDE_STUB_LOG="$TMP/claude-log-$P"; mkdir -p "$CLAUDE_STUB_LOG"
  node -e "require('fs').writeFileSync('$TMP/claude.json', JSON.stringify({projects:{['$TMP/$C']:{hasTrustDialogAccepted:true}}}))"
  write_issues "$BR" "$ISSUE" "$ID" "${4:-src/**}"
  cat > "$TMP/fleet.config.json" <<JSON
{
  "repo": "acme/host", "epic": 1,
  "targets": [{ "repo": "acme/api", "localPath": "$TMP/$C", "defaultBranch": "main" }],
  "workers": { "a": { "mode": "local" } },
  "wipCap": 4, "worktreesDir": "$TMP/worktrees-$P", "stateDir": "$TMP/state-$P",
  "pluginRoot": "$PLUGIN", "noMovementLimit": 99
}
JSON
}
# write_issues <branch> <issue> <id> <allowed glob>: the epic and one package.
write_issues() {
  node - "$TMP/gh" "$@" <<'JS'
const fs = require('fs'); const [dir, branch, issue, id, allowed] = process.argv.slice(2);
const body = '**Part of** #1 · **Phase 1 · x** · **Repo:** `acme/api`\n\n## Goal\nx\n\n### SCOPE.json\n```json\n'
  + JSON.stringify({ feature: 'f', branch, allowedPaths: [allowed], forbiddenPaths: [], dependsOn: [], execution: { model: 'default', pattern: 'solo' } })
  + '\n```\n';
fs.writeFileSync(`${dir}/issues.json`, JSON.stringify([
  { number: 1, title: 'Epic: program T', body: '', state: 'OPEN', labels: ['epic'] },
  { number: Number(issue), title: `${id} Identity`, body, state: 'OPEN', labels: ['agent-ready', 'cell:queued', 'worker:a'] },
], null, 2));
fs.writeFileSync(`${dir}/prs.json`, '[]'); fs.writeFileSync(`${dir}/labels.json`, '{}');
fs.writeFileSync(`${dir}/comments.json`, '{}'); fs.writeFileSync(`${dir}/writes.log`, '');
JS
}
fleet() { node "$FLEET" "$@" --config "$TMP/fleet.config.json"; }

alarms() { printf '%s' "$1" | node -e "const r=JSON.parse(require('fs').readFileSync(0,'utf8')); console.log(r.alarms.filter(a=>a.code===process.argv[1]).map(a=>a.issue).sort().join(' '))" "$2"; }
launched() { printf '%s' "$1" | node -e "const r=JSON.parse(require('fs').readFileSync(0,'utf8')); console.log(r.launched.map(l=>l.issue).sort().join(' '))"; }
detail() { printf '%s' "$1" | node -e "const r=JSON.parse(require('fs').readFileSync(0,'utf8')); console.log(r.alarms.filter(a=>a.code===process.argv[1]).map(a=>a.detail).join(' | '))" "$2"; }
doctor_line() { fleet doctor 2>/dev/null | grep 'commit identity'; }
# idents <bare remote> <range>: "author|committer" per commit, one per line.
idents() { git --git-dir "$1" log --format='%an <%ae>|%cn <%ce>' "$2"; }

# --- A. a clone with an identity: the scope commit carries it ------------------
phase 1 named api
OUT=$(fleet cycle --json 2>/dev/null)
assert_empty "$(alarms "$OUT" launch-identity-missing)" "A: no identity-missing alarm in the dry run"
assert_eq "11" "$(launched "$OUT")" "A: the dry run launches"
OUT=$(fleet cycle --apply --json 2>/dev/null)
assert_eq "11" "$(launched "$OUT")" "A: the applied cycle launches"
SCOPE_LINE=$(git --git-dir "$TMP/api.git" log --format='%s|%an <%ae>|%cn <%ce>' main..feat/t1-1-named | grep '^T1.1: scope|')
assert_eq "T1.1: scope|Ada Human <ada@example.invalid>|Ada Human <ada@example.invalid>" "$SCOPE_LINE" "A: the scope commit's author and committer are the clone's identity"
L=$(doctor_line)
assert_contains "$L" "ok" "A: doctor passes the identity line"
assert_contains "$L" "Ada Human <ada@example.invalid>" "A: doctor prints the identity it will commit as"
assert_contains "$L" "acme/api" "A: doctor names the target"

# --- B. the re-cut of an adopted worktree carries it too ------------------------
# The launch dies after its push, the coordinator re-cuts the lane, and the
# next cycle adopts the worktree and commits the new lane as a re-cut.
phase 2 recut api
OUT=$(FLEET_TEST_HOOKS=1 FLEET_CRASH_AT=after-push fleet cycle --apply --json 2>/dev/null)
assert_eq "T1.2: scope" "$(git --git-dir "$TMP/api.git" log --format=%s main..feat/t1-2-recut | head -1)" "B: the crashed launch pushed its scope commit"
write_issues "feat/t1-2-recut" 12 "T1.2" "docs/**"
OUT=$(fleet cycle --apply --json 2>/dev/null)
assert_eq "12" "$(launched "$OUT")" "B: the next cycle adopts and launches"
RECUT_LINE=$(git --git-dir "$TMP/api.git" log --format='%s|%an <%ae>|%cn <%ce>' main..feat/t1-2-recut | grep '^T1.2: scope re-cut|')
assert_eq "T1.2: scope re-cut|Ada Human <ada@example.invalid>|Ada Human <ada@example.invalid>" "$RECUT_LINE" "B: the re-cut commit's author and committer are the clone's identity"

# --- C. no commit fleet makes names fleet ----------------------------------------
ALL="$(idents "$TMP/api.git" main..feat/t1-1-named)
$(idents "$TMP/api.git" main..feat/t1-2-recut)"
assert_nonempty "$ALL" "C: the branches carry commits"
assert_not_contains "$ALL" "fleet" "C: no commit on a package branch names fleet"
assert_not_contains "$ALL" "nodots.invalid" "C: no commit on a package branch uses a made-up address"

# --- D. a clone with no identity: refused identity-missing ----------------------
clone anon
git -C "$TMP/anon" config --unset user.name; git -C "$TMP/anon" config --unset user.email
phase 4 anon anon
OUT=$(fleet cycle --json 2>/dev/null)
assert_eq "14" "$(alarms "$OUT" launch-identity-missing)" "D: a clone with no identity is refused identity-missing in the dry run"
assert_empty "$(launched "$OUT")" "D: nothing is launched in the dry run"
D=$(detail "$OUT" launch-identity-missing)
assert_contains "$D" "$TMP/anon" "D: the alarm names the clone"
assert_contains "$D" "git -C $TMP/anon config user.name" "D: the alarm names the user.name fix"
assert_contains "$D" "git -C $TMP/anon config user.email" "D: the alarm names the user.email fix"
OUT=$(fleet cycle --apply --json 2>/dev/null)
assert_eq "14" "$(alarms "$OUT" launch-identity-missing)" "D: the applied cycle refuses too"
assert_empty "$(launched "$OUT")" "D: nothing is launched in the applied cycle"
[ -d "$TMP/worktrees-anon" ] && _fail "D: no worktree is created for a refused launch" "worktrees dir exists" || _pass "D: no worktree is created for a refused launch"
assert_empty "$(git --git-dir "$TMP/anon.git" branch --list 'feat/*')" "D: no branch is pushed"
assert_empty "$(ls "$CLAUDE_STUB_LOG")" "D: no worker was started"
L=$(doctor_line)
assert_contains "$L" "FAIL" "D: doctor fails the identity line"
assert_contains "$L" "git -C $TMP/anon config user.name" "D: doctor names the fix"

# --- E. a name with no email is refused too -------------------------------------
git -C "$TMP/anon" config user.name "Ada Human"
OUT=$(fleet cycle --json 2>/dev/null)
assert_eq "14" "$(alarms "$OUT" launch-identity-missing)" "E: user.name without user.email is refused identity-missing"
assert_contains "$(detail "$OUT" launch-identity-missing)" "user.email" "E: the alarm names the missing value"

finish
