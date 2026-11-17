#!/usr/bin/env bash
# IV gate: program I end to end. A bare remote and a clone whose identity is
# set, driven through `fleet cycle --apply` with the gh and claude stubs. The
# real scripts/check-commit-identity.sh then runs over the branch fleet pushed:
# fleet's scope commit passes, and a commit made as fleet, one with a Claude
# co-author trailer, and one with `Agent-Assisted: claude` each fail it, by
# name. `Agent-Assisted: yes` passes. A clone with no identity is refused
# identity-missing and nothing is pushed.
#
# The global and system git config are cut off for the whole script, so an
# identity on the machine running the suite cannot stand in for the clone's.
set -uo pipefail
cd "$(dirname "$0")"
. ./lib.sh

HERE=$(pwd -P)
FLEET="$(cd .. && pwd -P)/bin/fleet.js"
PLUGIN="$(cd ../../agentic-work-packages && pwd -P)"
CHECK="$(cd ../../.. && pwd -P)/scripts/check-commit-identity.sh"
assert_file "$FLEET" "fleet.js exists"
assert_file "$CHECK" "check-commit-identity.sh exists"

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

STUB="$TMP/stub"; mkdir -p "$STUB" "$TMP/gh"
cp "$HERE/stubs/gh.js" "$STUB/gh.js"
printf '#!/usr/bin/env bash\nexec node "%s/gh.js" "$@"\n' "$STUB" > "$STUB/gh"; chmod +x "$STUB/gh"
cp "$HERE/stubs/claude.sh" "$STUB/claude"; chmod +x "$STUB/claude"
# The stub sleeps before it writes, so a read that does not wait fails here too.
export GH_STUB_DIR="$TMP/gh" CLAUDE_STUB_TARGET="acme/api" CLAUDE_STUB_DELAY=1
export GH_BIN="$STUB/gh" CLAUDE_BIN="$STUB/claude"
export CLAUDE_CONFIG_FILE="$TMP/claude.json"
unset CLAUDECODE
printf '{}' > "$TMP/gh/ci.json"

# phase <n> <tag> <clone>: one queued package I9.<n> (issue 10+<n>) on branch
# feat/i9-<n>-<tag> against <clone>, with fresh state and claude log.
phase() {
  N="$1"; P="$2"; C="$3"; ISSUE=$((10 + N)); ID="I9.$N"; BR="feat/i9-$N-$P"
  export GH_STUB_REMOTE="$TMP/$C.git"
  export CLAUDE_STUB_LOG="$TMP/claude-log-$P"; mkdir -p "$CLAUDE_STUB_LOG"
  node -e "require('fs').writeFileSync('$TMP/claude.json', JSON.stringify({projects:{['$TMP/$C']:{hasTrustDialogAccepted:true}}}))"
  node - "$TMP/gh" "$BR" "$ISSUE" "$ID" <<'JS'
const fs = require('fs'); const [dir, branch, issue, id] = process.argv.slice(2);
const body = '**Part of** #1 · **Phase 1 · x** · **Repo:** `acme/api`\n\n## Goal\nx\n\n### SCOPE.json\n```json\n'
  + JSON.stringify({ feature: 'f', branch, allowedPaths: ['src/**'], forbiddenPaths: [], dependsOn: [], execution: { model: 'default', pattern: 'solo' } })
  + '\n```\n';
fs.writeFileSync(`${dir}/issues.json`, JSON.stringify([
  { number: 1, title: 'Epic: program I', body: '', state: 'OPEN', labels: ['epic'] },
  { number: Number(issue), title: `${id} Identity gate`, body, state: 'OPEN', labels: ['agent-ready', 'cell:queued', 'worker:a'] },
], null, 2));
fs.writeFileSync(`${dir}/prs.json`, '[]'); fs.writeFileSync(`${dir}/labels.json`, '{}');
fs.writeFileSync(`${dir}/comments.json`, '{}'); fs.writeFileSync(`${dir}/writes.log`, '');
JS
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
fleet() { node "$FLEET" "$@" --config "$TMP/fleet.config.json"; }

alarms() { printf '%s' "$1" | node -e "const r=JSON.parse(require('fs').readFileSync(0,'utf8')); console.log(r.alarms.filter(a=>a.code===process.argv[1]).map(a=>a.issue).sort().join(' '))" "$2"; }
launched() { printf '%s' "$1" | node -e "const r=JSON.parse(require('fs').readFileSync(0,'utf8')); console.log(r.launched.map(l=>l.issue).sort().join(' '))"; }

# check <range>: run the real identity check in the verify clone. Sets CHECK_OUT
# and CHECK_RC.
check() { CHECK_OUT=$(cd "$TMP/verify" && bash "$CHECK" "${1%%..*}" "${1##*..}" 2>&1); CHECK_RC=$?; }
# add_commit <message> [git -c args...]: an empty commit on the verify clone's
# HEAD; prints its short sha.
add_commit() {
  local msg=$1; shift
  git -C "$TMP/verify" "$@" commit -q --allow-empty -m "$msg" && git -C "$TMP/verify" rev-parse --short HEAD
}

# --- 1. fleet's scope commit carries the clone's identity, and passes ----------
clone api
phase 1 gate api
OUT=$(fleet cycle --apply --json 2>/dev/null)
assert_eq "11" "$(launched "$OUT")" "1: the applied cycle launches"
assert_empty "$(alarms "$OUT" launch-identity-missing)" "1: no identity-missing alarm"
# The worker is detached; wait for the stub's files before reading anything.
wait_for_file "$CLAUDE_STUB_LOG/I9.1.1.env" 20
assert_file "$CLAUDE_STUB_LOG/I9.1.1.env" "1: the worker was started"
SCOPE_LINE=$(git --git-dir "$TMP/api.git" log --format='%s|%an <%ae>|%cn <%ce>' main..feat/i9-1-gate | grep '^I9.1: scope|')
assert_eq "I9.1: scope|Ada Human <ada@example.invalid>|Ada Human <ada@example.invalid>" "$SCOPE_LINE" "1: the scope commit's author and committer are the clone's identity"

# A fresh clone of what fleet pushed; the check runs over its range there.
git clone -q "$TMP/api.git" "$TMP/verify" 2>/dev/null
git -C "$TMP/verify" checkout -q -b gate origin/feat/i9-1-gate
git -C "$TMP/verify" config user.email ada@example.invalid; git -C "$TMP/verify" config user.name "Ada Human"
check origin/main..origin/feat/i9-1-gate
assert_eq "0" "$CHECK_RC" "1: check-commit-identity passes over the branch fleet pushed"
assert_contains "$CHECK_OUT" "OK  " "1: the check reports OK"
assert_not_contains "$CHECK_OUT" "0 commit(s)" "1: the check saw fleet's commits, not an empty range"
BASE=$(git -C "$TMP/verify" rev-parse HEAD)

# --- 2. a commit authored as fleet fails, by name -------------------------------
FLEET_SHA=$(add_commit "work as fleet" -c user.name=fleet -c user.email=fleet@nodots.invalid)
check "$BASE..HEAD"
assert_eq "1" "$CHECK_RC" "2: a commit authored as fleet fails the check"
assert_contains "$CHECK_OUT" "FAIL  $FLEET_SHA  author name is fleet" "2: the check names the fleet commit and its author"
check "origin/main..HEAD"
assert_eq "1" "$CHECK_RC" "2: the whole branch fails once it carries the fleet commit"
assert_contains "$CHECK_OUT" "1 of " "2: only the fleet commit fails, not fleet's scope commit"
git -C "$TMP/verify" reset -q --hard "$BASE"

# --- 3. trailers: a Claude co-author fails, Agent-Assisted: yes passes, -----------
#        Agent-Assisted: claude fails
CO_SHA=$(add_commit "$(printf 'implement\n\nCo-Authored-By: Claude <noreply@anthropic.com>')")
check "$BASE..HEAD"
assert_eq "1" "$CHECK_RC" "3: a Co-Authored-By: Claude trailer fails the check"
assert_contains "$CHECK_OUT" "FAIL  $CO_SHA  trailer names an AI model or vendor: Co-Authored-By: Claude <noreply@anthropic.com>" "3: the check names the co-authored commit and its trailer"
git -C "$TMP/verify" reset -q --hard "$BASE"

YES_SHA=$(add_commit "$(printf 'implement\n\nAgent-Assisted: yes')")
check "$BASE..HEAD"
assert_eq "0" "$CHECK_RC" "3: an Agent-Assisted: yes trailer passes the check"
assert_not_contains "$CHECK_OUT" "$YES_SHA" "3: the check does not name the Agent-Assisted: yes commit"

AC_SHA=$(add_commit "$(printf 'implement more\n\nAgent-Assisted: claude')")
check "$BASE..HEAD"
assert_eq "1" "$CHECK_RC" "3: an Agent-Assisted: claude trailer fails the check"
assert_contains "$CHECK_OUT" "FAIL  $AC_SHA  trailer names an AI model or vendor: Agent-Assisted: claude" "3: the check names the Agent-Assisted: claude commit"
assert_not_contains "$CHECK_OUT" "$YES_SHA" "3: the Agent-Assisted: yes commit beside it still passes"
assert_contains "$CHECK_OUT" "1 of 2 commit(s)" "3: one of the two commits fails"

# --- 4. a clone with no identity: refused identity-missing, nothing pushed -------
clone anon
git -C "$TMP/anon" config --unset user.name; git -C "$TMP/anon" config --unset user.email
phase 4 anon anon
OUT=$(fleet cycle --apply --json 2>/dev/null)
assert_eq "14" "$(alarms "$OUT" launch-identity-missing)" "4: a clone with no identity is refused identity-missing"
assert_empty "$(launched "$OUT")" "4: nothing is launched"
# Give a wrongly started worker the time the stub needs to write, then look.
sleep 2
assert_empty "$(ls "$CLAUDE_STUB_LOG")" "4: no worker was started"
assert_empty "$(git --git-dir "$TMP/anon.git" for-each-ref --format='%(refname)' refs/heads | grep -v '^refs/heads/main$')" "4: no branch is pushed"

finish
