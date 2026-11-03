#!/usr/bin/env bash
# Fixture test for adopting an existing worktree, against a bare remote.
#
# What is proved: a worktree left with an uncommitted lane file and no remote
# branch (the first launch failed at `git add` because the clone ignored
# .agentic/) is adopted by the next applied cycle, which commits the lane and
# pushes the branch before any worker starts; an adopted worktree that is
# already pushed and current makes no commit and no push; a rejected adoption
# push is a launch-claim alarm and starts no worker; the worker prompt names
# the worktree's .claude/worker-contract.md when there is one, and the plugin's
# copy otherwise.
set -uo pipefail
cd "$(dirname "$0")"
. ./lib.sh

HERE=$(pwd -P)
FLEET="$(cd .. && pwd -P)/bin/fleet.js"
PLUGIN="$(cd ../../agentic-work-packages && pwd -P)"
PLUGIN_CONTRACT="$PLUGIN/skills/agentic-work-packages/assets/worker-contract.md"
assert_file "$FLEET" "fleet.js exists"
assert_file "$PLUGIN_CONTRACT" "the plugin's worker contract exists"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
TMP=$(cd "$TMP" && pwd -P)

# --- a real remote and clone --------------------------------------------------
git init -q --bare -b main "$TMP/remote.git"
git clone -q "$TMP/remote.git" "$TMP/clone" 2>/dev/null
git -C "$TMP/clone" checkout -q -b main 2>/dev/null || true
git -C "$TMP/clone" config user.email f@example.invalid; git -C "$TMP/clone" config user.name fixture
printf '# api\n' > "$TMP/clone/README.md"
git -C "$TMP/clone" add -A && git -C "$TMP/clone" commit -qm init && git -C "$TMP/clone" push -q -u origin main

# --- stubs -------------------------------------------------------------------
STUB="$TMP/stub"; mkdir -p "$STUB" "$TMP/gh" "$TMP/claude-log"
cp "$HERE/stubs/gh.js" "$STUB/gh.js"
printf '#!/usr/bin/env bash\nexec node "%s/gh.js" "$@"\n' "$STUB" > "$STUB/gh"; chmod +x "$STUB/gh"
cp "$HERE/stubs/claude.sh" "$STUB/claude"; chmod +x "$STUB/claude"
# A git that records every invocation the fleet makes, so "no commit and no
# push" is observed rather than inferred from refs.
REAL_GIT=$(command -v git)
cat > "$STUB/git" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TMP/git.log"
exec "$REAL_GIT" "\$@"
SH
chmod +x "$STUB/git"; : > "$TMP/git.log"
export GH_STUB_DIR="$TMP/gh" GH_STUB_REMOTE="$TMP/remote.git" CLAUDE_STUB_LOG="$TMP/claude-log" CLAUDE_STUB_TARGET="acme/api"
export GH_BIN="$STUB/gh" CLAUDE_BIN="$STUB/claude" GIT_BIN="$STUB/git"
export CLAUDE_CONFIG_FILE="$TMP/claude.json"
node -e "require('fs').writeFileSync('$TMP/claude.json', JSON.stringify({projects:{['$TMP/clone']:{hasTrustDialogAccepted:true}}}))"

scope_body() { # branch
  printf '**Part of** #1 · **Phase 1 · x** · **Repo:** `acme/api`\n\n## Goal\nx\n\n### SCOPE.json\n```json\n{"feature":"f","branch":"%s","allowedPaths":["src/**"],"forbiddenPaths":["contracts/**"],"dependsOn":[],"execution":{"model":"default","pattern":"solo"}}\n```\n' "$1"
}
node - "$TMP/gh" "$(scope_body feat/t1-1-first)" "$(scope_body feat/t1-2-second)" "$(scope_body feat/t1-3-taken)" <<'JS'
const fs = require('fs'); const [dir, b11, b12, b13] = process.argv.slice(2);
fs.writeFileSync(`${dir}/issues.json`, JSON.stringify([
  { number: 1, title: 'Epic: program T', body: '', state: 'OPEN', labels: ['epic'] },
  { number: 10, title: 'T1.1 Incident replay', body: b11, state: 'OPEN', labels: ['agent-ready', 'cell:queued', 'worker:a'] },
  { number: 11, title: 'T1.2 Already pushed', body: b12, state: 'OPEN', labels: ['agent-ready', 'cell:queued', 'worker:a'] },
  { number: 12, title: 'T1.3 Branch taken', body: b13, state: 'OPEN', labels: ['agent-ready', 'cell:queued', 'worker:a'] },
], null, 2));
fs.writeFileSync(`${dir}/prs.json`, '[]');
fs.writeFileSync(`${dir}/labels.json`, '{}'); fs.writeFileSync(`${dir}/comments.json`, '{}'); fs.writeFileSync(`${dir}/writes.log`, '');
JS

cat > "$TMP/fleet.config.json" <<JSON
{
  "repo": "acme/host", "epic": 1,
  "targets": [{ "repo": "acme/api", "localPath": "$TMP/clone", "defaultBranch": "main", "ci": { "gate": "external", "verifiedBy": "the fixture" } }],
  "workers": { "a": { "mode": "local" } },
  "wipCap": 4, "worktreesDir": "$TMP/worktrees", "stateDir": "$TMP/state",
  "pluginRoot": "$PLUGIN", "maxEscalations": 2, "noMovementLimit": 9, "sessionTimeoutMinutes": 5,
  "models": { "cheapest": "haiku", "default": null, "strongest": "opus" }
}
JSON
fleet() { node "$FLEET" "$@" --config "$TMP/fleet.config.json"; }
wait_exit() { local f="$TMP/state/logs/$1.exit" i=0; until [ -f "$f" ] || [ $i -ge 60 ]; do sleep 0.5; i=$((i + 1)); done; [ -f "$f" ]; }
remote_sha() { git --git-dir "$TMP/remote.git" rev-parse -q --verify "refs/heads/$1" 2>/dev/null || echo none; }
argv_count() { ls "$TMP/claude-log" | grep -c "^$1\..*\.argv$" || true; }
export CLAUDE_STUB_MODE_T1_1=silent CLAUDE_STUB_MODE_T1_2=silent CLAUDE_STUB_MODE_T1_3=silent

# --- A. incident replay: the first launch fails at `git add` ------------------
WT1="$TMP/worktrees/api-t1-1"
LANE1=".agentic/cells/feat/t1-1-first/SCOPE.json"
printf '.agentic/\n' >> "$TMP/clone/.git/info/exclude"
OUT=$(FLEET_ONLY_ISSUE=10 fleet cycle --apply --json 2>/dev/null)
assert_contains "$OUT" '"code": "launch-commit"' "A: with .agentic/ ignored, the first launch fails at its commit"
assert_file "$WT1/$LANE1" "A: the failed launch left the lane file in the worktree"
assert_eq "none" "$(remote_sha feat/t1-1-first)" "A: the failed launch pushed no branch"
assert_eq "0" "$(argv_count T1.1)" "A: the failed launch started no worker"

# Still ignored: adoption must not launch over a lane it cannot commit.
OUT=$(FLEET_ONLY_ISSUE=10 fleet cycle --apply --json 2>/dev/null)
assert_contains "$OUT" '"code": "launch-commit"' "A: while the lane cannot be committed, adoption fails at the commit"
assert_eq "0" "$(argv_count T1.1)" "A: and starts no worker"
assert_eq "none" "$(remote_sha feat/t1-1-first)" "A: and pushes nothing"

# The ignore is fixed; the worktree carries its own in-repo contract.
sed -i.bak '/^\.agentic\/$/d' "$TMP/clone/.git/info/exclude"
mkdir -p "$WT1/.claude" && printf '# contract\n' > "$WT1/.claude/worker-contract.md"
OUT=$(FLEET_ONLY_ISSUE=10 fleet cycle --apply --json 2>/dev/null)
assert_contains "$OUT" '"adopted": true' "A: the next applied cycle adopts the worktree"
assert_eq "1" "$(argv_count T1.1)" "A: and starts one worker"
assert_nonempty "$(git -C "$WT1" ls-files -- "$LANE1")" "A: the adopted lane file is committed"
git -C "$WT1" diff --quiet HEAD -- "$LANE1"; assert_eq 0 $? "A: the committed lane matches the working copy"
assert_eq "T1.1: scope" "$(git -C "$WT1" log -1 --format=%s -- "$LANE1")" "A: the lane commit is '<ID>: scope', as a new worktree's is"
assert_eq "$(git -C "$WT1" rev-parse HEAD)" "$(remote_sha feat/t1-1-first)" "A: the branch exists on the remote at the worktree's head"
assert_eq "origin/feat/t1-1-first" "$(git -C "$WT1" rev-parse --abbrev-ref '@{u}' 2>/dev/null)" "A: the branch tracks its own remote branch"
assert_nonempty "$(git -C "$WT1" status --porcelain -- .claude/worker-contract.md)" "A: only the lane is committed; the untracked contract stays untracked"
ARGV=$(cat "$TMP/claude-log/T1.1.1.argv")
assert_contains "$ARGV" "Follow the worker contract at .claude/worker-contract.md in this worktree" "A: the prompt names the worktree's .claude/worker-contract.md"
assert_not_contains "$ARGV" "$PLUGIN_CONTRACT" "A: and not the plugin's copy"

# --- B. an adopted worktree already pushed and current: no commit, no push ----
OUT=$(FLEET_ONLY_ISSUE=11 fleet cycle --apply --json 2>/dev/null)
SHA2=$(remote_sha feat/t1-2-second)
assert_ne "none" "$SHA2" "B: setup: the new worktree's claim was pushed"
ARGV=$(cat "$TMP/claude-log/T1.2.1.argv")
assert_contains "$ARGV" "Follow the worker contract at $PLUGIN_CONTRACT, in order." "B: with no .claude/worker-contract.md in the worktree, the prompt names the plugin's copy"
assert_not_contains "$ARGV" ".claude/worker-contract.md" "B: and not the in-repo path"
wait_exit 11-1 && _pass "B: the silent worker exited" || _fail "B: the silent worker exited" "no exit file"
: > "$TMP/git.log"
OUT=$(FLEET_ONLY_ISSUE=11 fleet cycle --apply --json 2>/dev/null)
assert_contains "$OUT" '"adopted": true' "B: the relaunch adopts the worktree"
assert_eq "2" "$(argv_count T1.2)" "B: and starts a worker"
GITLOG=$(grep -- "$TMP/worktrees/api-t1-2" "$TMP/git.log")
assert_nonempty "$GITLOG" "B: the git stub saw the adoption's git calls"
assert_not_contains "$GITLOG" " commit" "B: adoption made no commit"
assert_not_contains "$GITLOG" " push" "B: adoption made no push"
assert_eq "$SHA2" "$(remote_sha feat/t1-2-second)" "B: the remote branch did not move"

# --- C. a rejected adoption push is a claim failure and starts no worker ------
WT3="$TMP/worktrees/api-t1-3"
git -C "$TMP/clone" checkout -q -b feat/t1-3-taken origin/main && printf 'theirs\n' > "$TMP/clone/theirs.txt" \
  && git -C "$TMP/clone" add -A && git -C "$TMP/clone" commit -qm "someone else's claim" \
  && git -C "$TMP/clone" push -q origin feat/t1-3-taken && git -C "$TMP/clone" checkout -q main && git -C "$TMP/clone" branch -q -D feat/t1-3-taken
THEIRS=$(remote_sha feat/t1-3-taken)
mkdir -p "$TMP/worktrees"
git -C "$TMP/clone" worktree add -q -b feat/t1-3-taken "$WT3" origin/main 2>/dev/null
OUT=$(FLEET_ONLY_ISSUE=12 fleet cycle --apply --json 2>/dev/null)
assert_contains "$OUT" '"code": "launch-claim"' "C: a rejected adoption push raises launch-claim"
assert_eq "0" "$(argv_count T1.3)" "C: and starts no worker"
assert_eq "$THEIRS" "$(remote_sha feat/t1-3-taken)" "C: the other claim is untouched (no force)"

finish
