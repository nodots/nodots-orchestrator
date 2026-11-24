#!/usr/bin/env bash
# Fixture test for require-coordinator.js (X0.2).
#
# In a session with FLEET_WORKER_ID set, the PreToolUse Bash hook refuses a
# command that files an issue, writes a coordinator label (agent-ready, cell:*,
# worker:*), or edits an issue's body or title. Without the variable it does
# nothing. A hook that cannot evaluate fails open, and says so.
set -uo pipefail
cd "$(dirname "$0")"
. ./lib.sh

HOOK_SRC="$(cd ../hooks && pwd -P)/require-coordinator.js"
assert_file "$HOOK_SRC" "the hook under test exists"

TMPROOT=$(mktemp -d)
trap 'rm -rf "$TMPROOT"' EXIT
ERRFILE="$TMPROOT/stderr"

# run_cmd <worker-id|-> <command>  -> sets EXIT, OUT, ERR
run_cmd() {
  local worker="$1" cmd="$2" json
  json=$(node -e 'process.stdout.write(JSON.stringify({hook_event_name:"PreToolUse",tool_name:"Bash",tool_input:{command:process.argv[1]}}))' "$cmd")
  if [ "$worker" = "-" ]; then
    OUT=$(printf '%s' "$json" | env -u FLEET_WORKER_ID node "$HOOK_SRC" 2>"$ERRFILE")
  else
    OUT=$(printf '%s' "$json" | FLEET_WORKER_ID="$worker" node "$HOOK_SRC" 2>"$ERRFILE")
  fi
  EXIT=$?
  ERR=$(cat "$ERRFILE")
}

refused() {
  run_cmd a "$1"
  assert_eq 2 "$EXIT" "refused · $1"
  assert_contains "$ERR" "BLOCKER.md" "refused · names BLOCKER.md · $1"
}
allowed() {
  run_cmd a "$1"
  assert_eq 0 "$EXIT" "allowed · $1"
}
passes_unset() {
  run_cmd - "$1"
  assert_eq 0 "$EXIT" "unset   · $1"
}

REFUSED=(
  'gh issue create --repo o/r --title x --label agent-ready'
  'gh issue create --repo o/r --title x'
  'gh issue new --repo o/r --title x'
  'gh -R o/r issue create --title x'
  'gh issue edit 5 --add-label worker:a'
  'gh issue edit 5 --remove-label cell:queued'
  'gh issue edit 5 --add-label agent-ready'
  'gh issue edit 5 --add-label=bug,worker:a'
  'gh issue edit 5 --remove-label=cell:done'
  'gh issue edit 5 --add-label "bug,cell:queued"'
  'gh issue edit 5 --body-file b.md'
  'gh issue edit 5 -F b.md'
  'gh issue edit 5 --body x'
  'gh issue edit 5 -b x'
  'gh issue edit 5 --title x'
  'gh issue edit 5 -t x'
  'gh issue edit 5 --body=x'
  'gh api -X POST repos/o/r/issues/5/labels -f labels[]=agent-ready'
  'gh api --method DELETE repos/o/r/issues/5/labels/worker:a'
  'gh api --method=PATCH repos/o/r/issues/5/labels'
  'gh api repos/o/r/issues/5/labels -f labels[]=worker:a'
  'gh api repos/o/r/issues/5 -F labels[]=agent-ready'
  'echo ok && gh issue create -t x'
  'echo ok; gh issue edit 5 --add-label worker:a'
  'true || gh issue create -t x'
  'echo ok | gh issue create -t x'
  $'echo ok\ngh issue create -t x'
  # review finding 1: gh not the first word of its segment
  'for n in 1 2; do gh issue edit $n --add-label agent-ready; done'
  'if true; then gh issue create -t x; fi'
  'while true; do gh issue create -t x; done'
  '{ gh issue create -t x; }'
  '! gh issue create -t x'
  'echo 1 2 | xargs -I{} gh issue edit {} --add-label agent-ready'
  'timeout 30 gh issue create -t x'
  'sudo -u me gh issue create -t x'
  "bash -c 'gh issue create -t x'"
  "xargs -n1 sh -c 'gh issue edit \$0 --add-label agent-ready'"
  'eval "gh issue create -t x"'
  $'bash <<EOF\ngh issue create -t x\nEOF'
  # review finding 2: backslash-newline continuation
  $'gh issue \\\ncreate -t x'
  $'gh issue edit 5 \\\n--add-label \\\nagent-ready'
  $'gh issue edit 5 --add-label "agent-\\\nready"'
  # review finding 3: labels are case-insensitive
  'gh issue edit 5 --add-label Agent-Ready'
  'gh issue edit 5 --remove-label CELL:queued'
  'gh issue edit 5 --add-label=bug,Worker:A'
  # review finding 4: attached short field flags
  'gh api repos/o/r/issues/5/labels -flabels[]=agent-ready'
  'gh api repos/o/r/issues/5 -Flabels[]=agent-ready'
  # review finding 5: gh api issue creation and body or title edits
  'gh api repos/o/r/issues -f title=x'
  'gh api repos/{owner}/{repo}/issues -f title=x'
  'gh api -X POST repos/o/r/issues --input i.json'
  'gh api -X PATCH repos/o/r/issues/5 -f body=x'
  'gh api --method PATCH /repos/o/r/issues/5 -F title=x'
  'gh api -X PATCH repos/o/r/issues/5 -fbody=x'
  'gh api -X PATCH repos/o/r/issues/5 --input b.json'
  # review finding 6: a command substitution inside double quotes
  'URL="$(gh issue create -t x)"'
  'echo "made `gh issue create -t x`"'
  'echo "$(echo "$(gh issue create -t x)")"'
  # gh's persistent -R between issue and its verb
  'gh issue -R o/r create -t x'
  # a comment ends at the newline
  $'# file it\ngh issue create -t x'
  # X0.2b: a function body, find -exec, parallel and a here-string fed to a shell
  'function f { gh issue create -t x; }; f'
  'f() { gh issue create -t x; }; f'
  'find . -exec gh issue create -t {} \;'
  "find . -name '*.md' -execdir gh issue create -t {} ';'"
  'find . -exec gh issue edit {} --add-label agent-ready +'
  "find . -exec sh -c 'gh issue create -t x' \\;"
  'parallel gh issue edit {} --add-label agent-ready ::: 1 2'
  'parallel -j4 gh issue create -t {} ::: a b'
  "parallel 'gh issue create -t {}' ::: a b"
  'bash <<< "gh issue create -t x"'
  "sh <<<'gh issue create -t x'"
  'bash -s <<< "gh issue edit 5 --add-label worker:a"'
  # X0.2b: a -f/-F field with no -X is a POST
  'gh api repos/o/r/issues/5/labels -f labels[]=agent-ready'
)
ALLOWED=(
  'gh pr create --title x --body y'
  'gh issue view 5'
  'gh issue comment 5 --body x'
  'gh issue edit 5 --add-label bug'
  'gh issue edit 5 --add-label=bug,docs'
  'gh api repos/o/r/issues/5'
  'gh api -X GET repos/o/r/issues/5/labels'
  'gh api repos/o/r/issues'
  'gh api repos/o/r/issues/5/comments -f body=x'
  'gh issue list --label agent-ready'
  'gh search issues --label agent-ready'
  # review finding 7: a heredoc body is data, not commands
  $'git commit -F - <<EOF\ngh issue create was used by coordinator\nEOF'
  $'cat <<\'EOF\' > notes.md\ngh issue edit 5 --add-label agent-ready\nEOF\necho done'
  $'cat <<-EOF\n\tgh issue create -t x\n\tEOF'
  $'git commit -F - <<"EOF"\ngh api repos/o/r/issues -f title=x\nEOF'
  'cat <<< "gh issue create"'
  $'git commit -m "$(cat <<\'EOF\'\nX0.2: gh issue create is refused\nEOF\n)"'
  $'gh pr create --title x --body "$(cat <<\'EOF\'\ngh issue edit 5 --add-label agent-ready\nEOF\n)" && echo done'
  # review finding 8: subcommand words found in flag values
  'gh pr create --title api --body x --label labels-x -F b.md'
  'gh pr create --title issue --body create'
  'gh pr edit 5 --title "gh issue create" --add-label agent-ready'
  # comments are not commands
  '# gh issue create -t x'
  'echo hi # gh issue create -t x'
  'echo gh-issue-create'
  # X0.2b: a labels field on a read is a query, not a write
  'gh api -X GET repos/o/r/issues -f labels=agent-ready'
  'gh api repos/o/r/issues -X GET -F labels=agent-ready'
  'gh api --method=GET repos/o/r/issues -f labels=worker:a'
  # X0.2b: the new forms judge commands, not data
  'find . -name "*.md" -exec grep -l "gh issue create" {} \;'
  'find . -exec echo {} \; -print'
  'parallel echo {} ::: "gh issue create"'
  'cat <<< "gh issue create -t x"'
  'function f { echo hi; }; f'
)

for c in "${REFUSED[@]}"; do refused "$c"; done
for c in "${ALLOWED[@]}"; do allowed "$c"; done
for c in "${REFUSED[@]}"; do passes_unset "$c"; done

# the message names the hook and the command it matched
run_cmd a 'gh issue create --title x'
assert_contains "$ERR" "require-coordinator" "the refusal names the hook"
assert_contains "$ERR" "gh issue create --title x" "the refusal names the matched command"
assert_contains "$ERR" "the coordinator files it" "the refusal says who files"
assert_empty "$OUT" "the refusal writes nothing to stdout"

# an empty FLEET_WORKER_ID is unset
run_cmd "" 'gh issue create --title x'
assert_eq 0 "$EXIT" "an empty FLEET_WORKER_ID is not a worker session"

# fail open, and loud
OUT=$(printf 'not json' | FLEET_WORKER_ID=a node "$HOOK_SRC" 2>"$ERRFILE"); EXIT=$?
ERR=$(cat "$ERRFILE")
assert_eq 0 "$EXIT" "malformed hook input fails open"
assert_contains "$ERR" "require-coordinator" "malformed hook input is reported on stderr"

OUT=$(printf '{"tool_input":{}}' | FLEET_WORKER_ID=a node "$HOOK_SRC" 2>"$ERRFILE"); EXIT=$?
assert_eq 0 "$EXIT" "an event with no command passes"

# wiring and copies
if node -e '
  const s = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
  const pre = (s.hooks && s.hooks.PreToolUse) || [];
  const ok = pre.some(e => e.matcher === "Bash" &&
    (e.hooks || []).some(h => (h.command || "").includes("require-coordinator.js")));
  process.exit(ok ? 0 : 1);
' ../../../../hooks/hooks.json; then
  _pass "hooks.json wires PreToolUse Bash to require-coordinator.js"
else
  _fail "hooks.json wires PreToolUse Bash to require-coordinator.js" "no such matcher"
fi

if node -e '
  const s = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
  const pre = (s.hooks && s.hooks.PreToolUse) || [];
  const ok = pre.some(e => e.matcher === "Bash" &&
    (e.hooks || []).some(h => (h.command || "").includes("require-coordinator.js")));
  process.exit(ok ? 0 : 1);
' ../settings-snippet.json; then
  _pass "settings-snippet.json wires PreToolUse Bash to require-coordinator.js"
else
  _fail "settings-snippet.json wires PreToolUse Bash to require-coordinator.js" "no such matcher"
fi

if diff -q "$HOOK_SRC" ../../../../hooks/require-coordinator.js >/dev/null 2>&1; then
  _pass "the plugin and asset copies of the hook are byte-identical"
else
  _fail "the plugin and asset copies of the hook are byte-identical" "they differ"
fi

finish
