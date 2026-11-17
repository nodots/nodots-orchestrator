#!/usr/bin/env bash
# Fixture test for require-handoff.js (N-5).
#
# Four repo states plus the loop guard. The hook blocks in exactly one of them:
# a non-default branch, uncommitted changes, and no written state.
set -uo pipefail
cd "$(dirname "$0")"
. ./lib.sh

HOOK="$(cd ../hooks && pwd -P)/require-handoff.js"
assert_file "$HOOK" "the hook under test exists"

TMPROOT=$(mktemp -d)
trap 'rm -rf "$TMPROOT"' EXIT
TMPROOT=$(cd "$TMPROOT" && pwd -P)
ERRFILE="$TMPROOT/stderr"

REPO="$TMPROOT/repo"
mkdir -p "$REPO"
git init -q -b development "$REPO"
git -C "$REPO" config user.email "fixture@example.invalid"
git -C "$REPO" config user.name "Fixture"
printf '# readme\n' > "$REPO/README.md"
git -C "$REPO" add -A
git -C "$REPO" commit -qm "fixture"

# The hook runs from outside the repo, as a plugin-installed hook does.
mkdir -p "$TMPROOT/fake-plugin/hooks"
cp "$HOOK" "$TMPROOT/fake-plugin/hooks/require-handoff.js"
PLUGIN="$TMPROOT/fake-plugin/hooks/require-handoff.js"

# run_stop [--active]  -> sets EXIT, OUT, ERR
run_stop() {
  local active=false
  [ "${1:-}" = "--active" ] && active=true
  local json
  json=$(printf '{"hook_event_name":"Stop","cwd":"%s","stop_hook_active":%s}' "$REPO" "$active")
  OUT=$(cd "$TMPROOT" && printf '%s' "$json" | node "$PLUGIN" 2>"$ERRFILE")
  EXIT=$?
  ERR=$(cat "$ERRFILE")
}

# A handoff that carries the required Plan check section: plan_handoff yes|no
plan_handoff() {
  printf '# handoff\n\n## Plan check\n\nPackage issue still matches: %s\n' "$1"
}

blocked() { case "$OUT" in *'"decision":"block"'*) return 0 ;; *) return 1 ;; esac; }

# --- 1. default branch, dirty: allowed ---------------------------------------
printf 'scratch\n' > "$REPO/scratch.txt"
run_stop
assert_eq 0 "$EXIT" "default branch: exit 0"
assert_empty "$OUT" "default branch: no block, whatever the tree looks like"

# --- 1b. an integration branch that is not the default, dirty: allowed -------
# A repo whose default is master and whose integration branch is develop: a
# session sitting on develop is not in a package lane, and the repo's own rules
# forbid writing a HANDOFF.md there, so the hook must not demand one.
git -C "$REPO" checkout -q -b develop
run_stop
assert_eq 0 "$EXIT" "develop, not the default: exit 0"
assert_empty "$OUT" "develop, not the default: no block, it is an integration branch"
git -C "$REPO" checkout -q development

# --- 2. feature branch, clean: allowed ---------------------------------------
rm -f "$REPO/scratch.txt"
git -C "$REPO" checkout -q -b feat/thing
run_stop
assert_eq 0 "$EXIT" "feature branch, clean tree: exit 0"
assert_empty "$OUT" "feature branch, clean tree: nothing to hand off"

# --- 3. feature branch, dirty, no written state: BLOCKED ---------------------
printf 'work in progress\n' > "$REPO/wip.txt"
run_stop
assert_eq 0 "$EXIT" "the block is a JSON decision, not a non-zero exit"
if blocked; then _pass "feature branch, dirty, no HANDOFF/BLOCKER: blocked"
else _fail "feature branch, dirty, no HANDOFF/BLOCKER: blocked" "got [$OUT]"; fi
assert_contains "$OUT" "HANDOFF.md" "the block names HANDOFF.md"
assert_contains "$OUT" "BLOCKER.md" "the block names BLOCKER.md"
assert_contains "$OUT" "feat/thing" "the block names the branch"
assert_empty "$ERR" "a block is not an error, so stderr stays empty"

# --- 3a. the loop guard ------------------------------------------------------
run_stop --active
assert_eq 0 "$EXIT" "stop_hook_active: exit 0"
assert_empty "$OUT" "stop_hook_active: allowed, so a block cannot loop"

# --- 4. feature branch, dirty, HANDOFF.md present: allowed -------------------
plan_handoff yes > "$REPO/HANDOFF.md"
run_stop
assert_empty "$OUT" "HANDOFF.md at the repo root satisfies the hook"

# --- 4c. Plan check: a bare HANDOFF.md is blocked, naming the section --------
printf '# handoff\n' > "$REPO/HANDOFF.md"
run_stop
assert_eq 0 "$EXIT" "bare HANDOFF.md: the block is a JSON decision"
if blocked; then _pass "HANDOFF.md without a Plan check section: blocked"
else _fail "HANDOFF.md without a Plan check section: blocked" "got [$OUT]"; fi
assert_contains "$OUT" "Plan check" "the block names the missing section"
assert_contains "$OUT" "Package issue still matches: yes" "the block shows the line to add"
assert_empty "$ERR" "a block is not an error, so stderr stays empty"

# heading present but no answer line: still blocked
printf '# handoff\n\n## Plan check\n\nlooks fine\n' > "$REPO/HANDOFF.md"
run_stop
if blocked; then _pass "Plan check heading without the answer line: blocked"
else _fail "Plan check heading without the answer line: blocked" "got [$OUT]"; fi

# an answer that is neither yes nor no: blocked
printf '# handoff\n\n## Plan check\n\nPackage issue still matches: maybe\n' > "$REPO/HANDOFF.md"
run_stop
if blocked; then _pass "Plan check answer other than yes/no: blocked"
else _fail "Plan check answer other than yes/no: blocked" "got [$OUT]"; fi

# the loop guard still wins over the Plan check block
run_stop --active
assert_empty "$OUT" "stop_hook_active: a bare HANDOFF.md does not block twice"

# either answer is allowed
plan_handoff no > "$REPO/HANDOFF.md"
run_stop
assert_empty "$OUT" "Plan check answer no is allowed"
plan_handoff yes > "$REPO/HANDOFF.md"
run_stop
assert_empty "$OUT" "Plan check answer yes is allowed"

# BLOCKER.md is exempt, even beside a bare HANDOFF.md
printf '# handoff\n' > "$REPO/HANDOFF.md"
printf '# blocker\n' > "$REPO/BLOCKER.md"
run_stop
assert_empty "$OUT" "BLOCKER.md exempts the Plan check"
rm -f "$REPO/BLOCKER.md"

# --- 4a. BLOCKER.md alone also satisfies it ----------------------------------
rm -f "$REPO/HANDOFF.md"
printf '# blocker\n' > "$REPO/BLOCKER.md"
run_stop
assert_empty "$OUT" "BLOCKER.md at the repo root satisfies the hook"

# --- 4b. and so does the branch's cell directory -----------------------------
rm -f "$REPO/BLOCKER.md"
mkdir -p "$REPO/.agentic/cells/feat/thing"
plan_handoff yes > "$REPO/.agentic/cells/feat/thing/HANDOFF.md"
run_stop
assert_empty "$OUT" "HANDOFF.md in the branch's cell directory satisfies the hook"
rm -rf "$REPO/.agentic"

# --- 5. fail open, and loud --------------------------------------------------
OUT=$(cd "$TMPROOT" && printf 'not json' | node "$PLUGIN" 2>"$ERRFILE"); EXIT=$?
ERR=$(cat "$ERRFILE")
assert_eq 0 "$EXIT" "malformed hook input fails open"
assert_empty "$OUT" "malformed hook input does not block"
assert_contains "$ERR" "require-handoff" "malformed hook input is reported on stderr"

# --- 6. outside a repo: allowed ----------------------------------------------
json=$(printf '{"hook_event_name":"Stop","cwd":"%s","stop_hook_active":false}' "$TMPROOT")
OUT=$(cd "$TMPROOT" && printf '%s' "$json" | node "$PLUGIN" 2>"$ERRFILE"); EXIT=$?
assert_eq 0 "$EXIT" "outside a git repo: exit 0"
assert_empty "$OUT" "outside a git repo: no block"

# --- 7. TaskCompleted (opt-in): same check, blocks by exit 2 -----------------
# The repo is on feat/thing with wip.txt uncommitted and no written state.
run_task_completed() {
  local json
  json=$(printf '{"hook_event_name":"TaskCompleted","cwd":"%s","stop_hook_active":true}' "$REPO")
  OUT=$(cd "$TMPROOT" && printf '%s' "$json" | node "$PLUGIN" 2>"$ERRFILE")
  EXIT=$?
  ERR=$(cat "$ERRFILE")
}

run_task_completed
assert_eq 2 "$EXIT" "TaskCompleted, dirty, no written state: exit 2 blocks"
assert_empty "$OUT" "TaskCompleted blocks through stderr, not a JSON decision"
assert_contains "$ERR" "HANDOFF.md" "TaskCompleted feedback names HANDOFF.md"
assert_contains "$ERR" "BLOCKER.md" "TaskCompleted feedback names BLOCKER.md"
assert_contains "$ERR" "feat/thing" "TaskCompleted feedback names the branch"

plan_handoff yes > "$REPO/HANDOFF.md"
run_task_completed
assert_eq 0 "$EXIT" "TaskCompleted with HANDOFF.md present: allowed"

printf '# handoff\n' > "$REPO/HANDOFF.md"
run_task_completed
assert_eq 2 "$EXIT" "TaskCompleted with a bare HANDOFF.md: exit 2 blocks"
assert_contains "$ERR" "Plan check" "TaskCompleted feedback names the missing section"
rm -f "$REPO/HANDOFF.md"

git -C "$REPO" checkout -q development
run_task_completed
assert_eq 0 "$EXIT" "TaskCompleted on the default branch: allowed"
git -C "$REPO" checkout -q feat/thing

# --- 8. H0.2: the lane check at the stop -------------------------------------
# The repo is on feat/thing with wip.txt untracked. Without a SCOPE.json the
# hook behaves exactly as above: a valid handoff allows the stop.
CELL="$REPO/.agentic/cells/feat/thing"
mkdir -p "$CELL"
plan_handoff yes > "$CELL/HANDOFF.md"
run_stop
assert_empty "$OUT" "no SCOPE.json: an untracked file with a handoff is allowed, as before"

# With a lane, the out-of-lane wip.txt blocks the stop, though the handoff is valid
printf '{ "allowedPaths": ["src/**"], "forbiddenPaths": ["src/secret/**"] }\n' > "$CELL/SCOPE.json"
run_stop
assert_eq 0 "$EXIT" "out-of-lane change: the block is a JSON decision"
if blocked; then _pass "an out-of-lane change left in the tree blocks the stop"
else _fail "an out-of-lane change left in the tree blocks the stop" "got [$OUT]"; fi
assert_contains "$OUT" "wip.txt" "the stop block names the path"
assert_contains "$OUT" "BLOCKER.md" "the stop block names the escalation route"
assert_empty "$ERR" "a lane block is not an error, so stderr stays empty"

# a BLOCKER.md does not excuse a change left outside the lane
printf '# blocker\n' > "$CELL/BLOCKER.md"
run_stop
if blocked; then _pass "BLOCKER.md does not excuse an out-of-lane change in the tree"
else _fail "BLOCKER.md does not excuse an out-of-lane change in the tree" "got [$OUT]"; fi
rm -f "$CELL/BLOCKER.md"

# the loop guard still wins
run_stop --active
assert_empty "$OUT" "stop_hook_active: the lane check does not block twice"

# TaskCompleted runs the same lane check, and blocks by exit 2
run_task_completed
assert_eq 2 "$EXIT" "TaskCompleted, out-of-lane change: exit 2 blocks"
assert_contains "$ERR" "wip.txt" "TaskCompleted feedback names the path"

# in lane, and lane artifacts only: allowed
rm -f "$REPO/wip.txt"
mkdir -p "$REPO/src"
printf 'x\n' > "$REPO/src/a.ts"
printf '# blocker\n' > "$CELL/BLOCKER.md"
run_stop
assert_empty "$OUT" "in-lane changes and lane artifacts (SCOPE, HANDOFF, BLOCKER) never block"
rm -f "$CELL/BLOCKER.md"

# staged, unstaged and committed out-of-lane changes all block, on a clean tree too
mkdir -p "$REPO/docs"
printf 'x\n' > "$REPO/docs/staged.md"
git -C "$REPO" add docs/staged.md
run_stop
assert_contains "$OUT" "docs/staged.md" "a staged out-of-lane change blocks the stop, named"

git -C "$REPO" add -A
git -C "$REPO" commit -qm "work, with an out-of-lane file"
run_stop
if blocked; then _pass "a committed out-of-lane change blocks the stop on a clean tree"
else _fail "a committed out-of-lane change blocks the stop on a clean tree" "got [$OUT]"; fi
assert_contains "$OUT" "docs/staged.md" "the committed path is named"

printf 'edit\n' >> "$REPO/README.md"
git -C "$REPO" rm -q --cached docs/staged.md
git -C "$REPO" commit -qm "drop it from the commit" >/dev/null
rm -f "$REPO/docs/staged.md"
run_stop
if blocked; then _pass "an unstaged out-of-lane edit blocks the stop"
else _fail "an unstaged out-of-lane edit blocks the stop" "got [$OUT]"; fi
assert_contains "$OUT" "README.md" "the unstaged path is named"
assert_not_contains "$OUT" "docs/staged.md" "a file added and removed on the branch is not named"
git -C "$REPO" checkout -q -- README.md

# the branch now carries only in-lane work and lane artifacts: allowed
run_stop
assert_empty "$OUT" "a branch with only in-lane work is allowed"

# the lane check does not run on the default branch
git -C "$REPO" checkout -q development
printf 'scratch\n' > "$REPO/scratch.txt"
mkdir -p "$REPO/.agentic/cells/development"
printf '{ "allowedPaths": ["src/**"] }\n' > "$REPO/.agentic/cells/development/SCOPE.json"
run_stop
assert_empty "$OUT" "default branch: the lane check does not run"
rm -rf "$REPO/scratch.txt" "$REPO/.agentic/cells/development"
git -C "$REPO" checkout -q feat/thing

# --- 9. C0.4: a lane measured from its baseBranch ----------------------------
# The #215 reproduction: development has one commit and origin/HEAD points at
# it; collection/t adds pkg1/x; feat/p2 is cut from collection/t with the lane
# p2/**. Measured from development, pkg1/x counts as feat/p2's change.
B="$TMPROOT/base"
git init -q --bare -b development "$B/remote.git"
git init -q -b development "$B/repo"
git -C "$B/repo" config user.email "fixture@example.invalid"
git -C "$B/repo" config user.name "Fixture"
printf '# readme\n' > "$B/repo/README.md"
git -C "$B/repo" add -A && git -C "$B/repo" commit -qm "development"
git -C "$B/repo" remote add origin "$B/remote.git"
git -C "$B/repo" push -q -u origin development
git -C "$B/repo" remote set-head origin development
git -C "$B/repo" checkout -q -b collection/t
mkdir -p "$B/repo/pkg1" && printf 'x\n' > "$B/repo/pkg1/x"
git -C "$B/repo" add -A && git -C "$B/repo" commit -qm "pkg1, merged into the integration branch"
git -C "$B/repo" push -q -u origin collection/t
git -C "$B/repo" checkout -q -b feat/p2
P2="$B/repo/.agentic/cells/feat/p2"
mkdir -p "$P2" "$B/repo/p2"
p2_scope() { # [baseBranch]
  if [ -n "${1:-}" ]; then printf '{ "allowedPaths": ["p2/**"], "baseBranch": "%s" }\n' "$1"
  else printf '{ "allowedPaths": ["p2/**"] }\n'; fi > "$P2/SCOPE.json"
}
p2_scope collection/t
printf 'y\n' > "$B/repo/p2/y"
git -C "$B/repo" add -A && git -C "$B/repo" commit -qm "p2 work"
plan_handoff yes > "$P2/HANDOFF.md"

run_base() { # <event> -> sets EXIT, OUT, ERR
  local json
  json=$(printf '{"hook_event_name":"%s","cwd":"%s","stop_hook_active":false}' "$1" "$B/repo")
  OUT=$(cd "$TMPROOT" && printf '%s' "$json" | node "$PLUGIN" 2>"$ERRFILE")
  EXIT=$?
  ERR=$(cat "$ERRFILE")
}

run_base Stop
assert_empty "$OUT" "baseBranch: only in-lane changes on a branch cut from an integration branch pass the Stop check"
assert_empty "$ERR" "baseBranch: the pass is silent"
run_base TaskCompleted
assert_eq 0 "$EXIT" "baseBranch: only in-lane changes pass the TaskCompleted check"

# an out-of-lane change is blocked, naming only that file
mkdir -p "$B/repo/docs" && printf 'x\n' > "$B/repo/docs/out.md"
run_base Stop
if blocked; then _pass "baseBranch: an out-of-lane change blocks the Stop check"
else _fail "baseBranch: an out-of-lane change blocks the Stop check" "got [$OUT]"; fi
assert_contains "$OUT" "docs/out.md" "baseBranch: the block names the out-of-lane file"
assert_not_contains "$OUT" "pkg1/x" "baseBranch: the block does not name the integration branch's work"
run_base TaskCompleted
assert_eq 2 "$EXIT" "baseBranch: an out-of-lane change blocks the TaskCompleted check"
assert_contains "$ERR" "docs/out.md" "baseBranch: TaskCompleted names the out-of-lane file"
assert_not_contains "$ERR" "pkg1/x" "baseBranch: TaskCompleted does not name the integration branch's work"
rm -rf "$B/repo/docs"

# with no origin ref, the local branch is the base
git -C "$B/repo" update-ref -d refs/remotes/origin/collection/t
run_base Stop
assert_empty "$OUT" "baseBranch: refs/heads/<baseBranch> is the base when origin has none"
git -C "$B/repo" update-ref refs/remotes/origin/collection/t collection/t

# with neither ref, the nearest-of-LANE_BASES rule holds, as before
p2_scope collection/gone
run_base Stop
assert_contains "$OUT" "pkg1/x" "baseBranch naming no ref: the merge base falls back to the nearest integration branch"

# without baseBranch, the current behavior holds: measured from development
p2_scope
run_base Stop
if blocked; then _pass "no baseBranch: the integration branch's work counts, as before"
else _fail "no baseBranch: the integration branch's work counts, as before" "got [$OUT]"; fi
assert_contains "$OUT" "pkg1/x" "no baseBranch: pkg1/x is named, as before"
p2_scope collection/t

# a session on the integration branch itself needs no HANDOFF
git -C "$B/repo" add -A && git -C "$B/repo" commit -qm "p2 scope" >/dev/null
# (the merged cell keeps feat/p2's HANDOFF.md, which is not collection/t's)
git -C "$B/repo" checkout -q collection/t
git -C "$B/repo" merge -q --no-edit feat/p2
printf 'scratch\n' > "$B/repo/scratch.txt"
run_base Stop
assert_empty "$OUT" "the branch a cell's SCOPE.json names as its baseBranch is not a package: no HANDOFF needed"
run_base TaskCompleted
assert_eq 0 "$EXIT" "the integration branch: TaskCompleted needs no HANDOFF either"
git -C "$B/repo" checkout -q -b feat/other
run_base Stop
if blocked; then _pass "a branch no SCOPE.json names as a base still needs a HANDOFF"
else _fail "a branch no SCOPE.json names as a base still needs a HANDOFF" "got [$OUT]"; fi

# --- the two shipped copies must not drift -----------------------------------
if diff -q "$HOOK" ../../../../hooks/require-handoff.js >/dev/null 2>&1; then
  _pass "the plugin and asset copies of the hook are byte-identical"
else
  _fail "the plugin and asset copies of the hook are byte-identical" "they differ"
fi

# --- the wiring agrees with the hook that exists -----------------------------
for f in ../../../../hooks/hooks.json ../settings-snippet.json; do
  if node -e '
    const s = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
    const stop = (s.hooks && s.hooks.Stop) || [];
    const cmds = stop.flatMap(e => (e.hooks || []).map(h => h.command || ""));
    process.exit(cmds.some(c => c.includes("require-handoff.js")) ? 0 : 1);
  ' "$f"; then
    _pass "$(basename "$f") wires the Stop hook"
  else
    _fail "$(basename "$f") wires the Stop hook" "no require-handoff.js command found"
  fi
done

finish
