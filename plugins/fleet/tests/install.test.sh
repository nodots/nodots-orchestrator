#!/usr/bin/env bash
# fleet install writes a target's worker files, and fleet doctor reports drift.
#
# The worker files are the three hooks under .claude/hooks/, the worker contract
# at .claude/worker-contract.md, and the hook registrations of the plugin's
# settings-snippet.json in .claude/settings.json. fleet install compares each
# with the target's base ref: the dry run lists add, update or same and writes
# nothing; --apply cuts chore/install-agentic-work-packages-<version> from the
# base ref in a worktree, commits once under the clone's identity, pushes, and
# prints the gh pr create command. fleet doctor fails a file that differs from
# the plugin's or is missing on the base ref, and a missing registration.
set -uo pipefail
cd "$(dirname "$0")"
. ./lib.sh

HERE=$(pwd -P)
FLEET="$(cd .. && pwd -P)/bin/fleet.js"
PLUGIN="$(cd ../../agentic-work-packages && pwd -P)"
ASSETS="$PLUGIN/skills/agentic-work-packages/assets"
assert_file "$FLEET" "fleet.js exists"
VERSION=$(node -p "require('$PLUGIN/.claude-plugin/plugin.json').version")
BRANCH="chore/install-agentic-work-packages-$VERSION"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
TMP=$(cd "$TMP" && pwd -P)

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
unset GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL EMAIL

git init -q --bare -b main "$TMP/remote.git"
git clone -q "$TMP/remote.git" "$TMP/clone" 2>/dev/null
git -C "$TMP/clone" checkout -q -b main 2>/dev/null || true
git -C "$TMP/clone" config user.email ada@example.invalid; git -C "$TMP/clone" config user.name "Ada Human"
printf '# api\n' > "$TMP/clone/README.md"
git -C "$TMP/clone" add -A && git -C "$TMP/clone" commit -qm init && git -C "$TMP/clone" push -q -u origin main

STUB="$TMP/stub"; mkdir -p "$STUB" "$TMP/gh"
cp "$HERE/stubs/gh.js" "$STUB/gh.js"
printf '#!/usr/bin/env bash\nexec node "%s/gh.js" "$@"\n' "$STUB" > "$STUB/gh"; chmod +x "$STUB/gh"
cp "$HERE/stubs/claude.sh" "$STUB/claude"; chmod +x "$STUB/claude"
export GH_STUB_DIR="$TMP/gh" GH_STUB_REMOTE="$TMP/remote.git" CLAUDE_STUB_TARGET="acme/api"
export GH_BIN="$STUB/gh" CLAUDE_BIN="$STUB/claude"
export CLAUDE_CONFIG_FILE="$TMP/claude.json"
node -e "require('fs').writeFileSync('$TMP/claude.json', JSON.stringify({projects:{['$TMP/clone']:{hasTrustDialogAccepted:true}}}))"
unset CLAUDECODE
printf '[{"number": 1, "title": "Epic", "body": "", "state": "OPEN", "labels": ["epic"]}]' > "$TMP/gh/issues.json"
printf '{}' > "$TMP/gh/ci.json"

cat > "$TMP/fleet.config.json" <<JSON
{
  "repo": "acme/host", "epic": 1,
  "targets": [{ "repo": "acme/api", "localPath": "$TMP/clone", "defaultBranch": "main" }],
  "workers": { "a": { "mode": "local" } },
  "wipCap": 4, "worktreesDir": "$TMP/worktrees", "stateDir": "$TMP/state",
  "pluginRoot": "$PLUGIN", "noMovementLimit": 99
}
JSON
fleet() { node "$FLEET" "$@" --config "$TMP/fleet.config.json"; }
FILES=".claude/hooks/enforce-scope.js .claude/hooks/require-handoff.js .claude/hooks/standards-preamble.js .claude/worker-contract.md .claude/settings.json"
src() {
  case "$1" in
    .claude/hooks/*) printf '%s/hooks/%s' "$PLUGIN" "${1#.claude/hooks/}" ;;
    .claude/worker-contract.md) printf '%s/worker-contract.md' "$ASSETS" ;;
    .claude/settings.json) printf '%s/settings-snippet.json' "$ASSETS" ;;
  esac
}
remote_branches() { git --git-dir "$TMP/remote.git" for-each-ref --format='%(refname:short)' refs/heads | sort | tr '\n' ' '; }
# land: merge the install branch into main, push, and delete the branch, as a
# merged PR would.
land() {
  git -C "$TMP/clone" fetch -q origin && git -C "$TMP/clone" merge -q --ff-only "origin/$BRANCH" \
    && git -C "$TMP/clone" push -q origin main && git -C "$TMP/clone" push -q origin --delete "$BRANCH"
}
doctor_lines() { fleet doctor 2>/dev/null | grep -E 'worker file|hook registration'; }

# --- A. dry run on an empty target: every file add, nothing written -------------
OUT=$(fleet install --target acme/api 2>&1); EXIT=$?
assert_eq 0 "$EXIT" "A: the dry run exits 0"
for f in $FILES; do
  assert_contains "$OUT" "add    $f" "A: the dry run lists $f as add"
done
assert_eq 5 "$(printf '%s\n' "$OUT" | grep -c '^add ')" "A: five files to add"
assert_eq "main " "$(remote_branches)" "A: the dry run pushes no branch"
assert_empty "$(git -C "$TMP/clone" status --porcelain)" "A: the dry run writes nothing to the clone"
assert_eq "" "$(git -C "$TMP/clone" branch --list "$BRANCH")" "A: the dry run creates no local branch"
[ -e "$TMP/worktrees" ] && _fail "A: the dry run creates no worktree" "$TMP/worktrees exists" || _pass "A: the dry run creates no worktree"

# --- B. doctor on the empty target fails each file -------------------------------
L=$(doctor_lines)
for f in $FILES; do
  assert_contains "$(printf '%s\n' "$L" | grep "worker file $f ")" "FAIL" "B: doctor fails missing $f"
done
assert_contains "$(printf '%s\n' "$L" | grep 'worker file .claude/hooks/enforce-scope.js ')" "fleet install --target acme/api" "B: the FAIL names the fix"
fleet doctor >/dev/null 2>&1; assert_ne 0 "$?" "B: doctor exits non-zero"

# --- C. --apply: one commit under the clone identity, pushed, byte for byte ------
OUT=$(fleet install --target acme/api --apply 2>&1); EXIT=$?
assert_eq 0 "$EXIT" "C: --apply exits 0"
assert_eq "$BRANCH main " "$(remote_branches)" "C: --apply pushes $BRANCH"
assert_eq 1 "$(git --git-dir "$TMP/remote.git" rev-list --count "main..$BRANCH")" "C: the branch is one commit on main"
assert_eq "Ada Human <ada@example.invalid>|Ada Human <ada@example.invalid>" "$(git --git-dir "$TMP/remote.git" log -1 --format='%an <%ae>|%cn <%ce>' "$BRANCH")" "C: the commit's author and committer are the clone's identity"
for f in $FILES; do
  git --git-dir "$TMP/remote.git" show "$BRANCH:$f" > "$TMP/got" 2>/dev/null
  cmp -s "$TMP/got" "$(src "$f")" && _pass "C: $f matches the plugin byte for byte" || _fail "C: $f matches the plugin byte for byte" "$(src "$f")"
done
assert_contains "$OUT" "gh pr create --repo acme/api --base main --head $BRANCH" "C: --apply prints the gh pr create command"
assert_eq '[]' "$(node -e "console.log(JSON.stringify(require('fs').existsSync('$TMP/gh/prs.json') ? JSON.parse(require('fs').readFileSync('$TMP/gh/prs.json','utf8')) : []))")" "C: --apply opens no PR"

# --- D. the branch still open: a second --apply refuses the existing branch ------
OUT=$(fleet install --target acme/api --apply 2>&1); EXIT=$?
assert_ne 0 "$EXIT" "D: --apply refuses while $BRANCH exists"
assert_contains "$OUT" "$BRANCH" "D: the refusal names the branch"

# --- E. installed: doctor passes, a second --apply creates no branch -------------
land
L=$(doctor_lines)
assert_empty "$(printf '%s\n' "$L" | grep '^FAIL')" "E: doctor passes every worker file on an installed target"
assert_eq 8 "$(printf '%s\n' "$L" | grep -c '^ok ')" "E: five files and three registrations are ok"
OUT=$(fleet install --target acme/api 2>&1)
assert_eq 5 "$(printf '%s\n' "$OUT" | grep -c '^same ')" "E: the dry run lists every file as same"
HEAD_BEFORE=$(git --git-dir "$TMP/remote.git" rev-parse main)
OUT=$(fleet install --target acme/api --apply 2>&1); EXIT=$?
assert_eq 0 "$EXIT" "E: a second --apply with nothing changed exits 0"
assert_eq "main " "$(remote_branches)" "E: a second --apply creates no branch"
assert_eq "$HEAD_BEFORE" "$(git --git-dir "$TMP/remote.git" rev-parse main)" "E: a second --apply adds no commit"

# --- F. a stale hook: doctor fails naming it, the dry run lists it update --------
printf '// stale\n' >> "$TMP/clone/.claude/hooks/require-handoff.js"
git -C "$TMP/clone" commit -qam "stale hook" && git -C "$TMP/clone" push -q origin main
L=$(doctor_lines)
assert_contains "$(printf '%s\n' "$L" | grep 'worker file .claude/hooks/require-handoff.js ')" "FAIL" "F: doctor fails the stale hook"
assert_contains "$(printf '%s\n' "$L" | grep 'worker file .claude/hooks/require-handoff.js ')" "fleet install --target acme/api" "F: the FAIL names the fix"
assert_eq 1 "$(printf '%s\n' "$L" | grep -c '^FAIL')" "F: only the stale hook fails"
OUT=$(fleet install --target acme/api 2>&1)
assert_contains "$OUT" "update .claude/hooks/require-handoff.js" "F: the dry run lists the stale hook as update"
assert_eq 4 "$(printf '%s\n' "$OUT" | grep -c '^same ')" "F: the other files are same"
OUT=$(fleet install --target acme/api --apply 2>&1); EXIT=$?
assert_eq 0 "$EXIT" "F: --apply after the first install landed exits 0"
land
assert_empty "$(doctor_lines | grep '^FAIL')" "F: after the install lands, doctor passes"

# --- G. settings with an unrelated key and a missing registration ----------------
node -e "
const fs = require('fs');
const s = JSON.parse(fs.readFileSync('$ASSETS/settings-snippet.json', 'utf8'));
delete s.hooks.SessionStart;
s.permissions = { allow: ['Bash(git status:*)'] };
fs.writeFileSync('$TMP/clone/.claude/settings.json', JSON.stringify(s, null, 2) + '\n');"
git -C "$TMP/clone" commit -qam "settings without SessionStart" && git -C "$TMP/clone" push -q origin main
L=$(doctor_lines)
assert_contains "$(printf '%s\n' "$L" | grep 'hook registration SessionStart')" "FAIL" "G: doctor fails the missing SessionStart registration"
assert_contains "$(printf '%s\n' "$L" | grep 'hook registration SessionStart')" "fleet install --target acme/api" "G: the FAIL names the fix"
assert_contains "$(printf '%s\n' "$L" | grep 'hook registration PreToolUse')" "ok" "G: the present PreToolUse registration is ok"
OUT=$(fleet install --target acme/api 2>&1)
assert_contains "$OUT" "update .claude/settings.json" "G: the dry run lists settings.json as update"
fleet install --target acme/api --apply >/dev/null 2>&1; assert_eq 0 "$?" "G: --apply exits 0"
GOT=$(git --git-dir "$TMP/remote.git" show "$BRANCH:.claude/settings.json")
assert_contains "$GOT" "Bash(git status:*)" "G: the unrelated key is kept"
assert_contains "$GOT" "standards-preamble.js" "G: the missing registration is added"
assert_eq 1 "$(printf '%s\n' "$GOT" | grep -c 'enforce-scope.js')" "G: a present registration is not duplicated"
land
assert_empty "$(doctor_lines | grep '^FAIL')" "G: after the install lands, doctor passes"

# --- H. a clone without identity is refused --------------------------------------
printf '// stale\n' >> "$TMP/clone/.claude/hooks/enforce-scope.js"
git -C "$TMP/clone" commit -qam "stale hook" && git -C "$TMP/clone" push -q origin main
git -C "$TMP/clone" config --unset user.name; git -C "$TMP/clone" config --unset user.email
OUT=$(fleet install --target acme/api --apply 2>&1); EXIT=$?
assert_ne 0 "$EXIT" "H: --apply without an identity exits non-zero"
assert_contains "$OUT" "launch-identity-missing" "H: the refusal is launch-identity-missing"
assert_eq "main " "$(remote_branches)" "H: no branch is pushed"

# --- I. usage: an unknown target exits 64 naming the configured ones -------------
OUT=$(fleet install --target acme/nope 2>&1); EXIT=$?
assert_eq 64 "$EXIT" "I: an unknown target exits 64"
assert_contains "$OUT" "acme/api" "I: the message names the configured targets"
OUT=$(fleet install 2>&1); EXIT=$?
assert_eq 64 "$EXIT" "I: a missing --target exits 64"

finish
