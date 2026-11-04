#!/usr/bin/env bash
# The SessionStart standards-preamble hook prints the repo's standards from
# .claude/standards.json, and nothing in a repo without one.
#
# Runs against both shipped copies of standards-preamble.js, so a gap in either
# copy fails the test. Every case checks the exit status, because stdout reaches
# the model only on exit 0 and the hook must never exit non-zero.
set -uo pipefail
cd "$(dirname "$0")"
. ./lib.sh

ASSET_HOOK="$(cd ../hooks && pwd -P)/standards-preamble.js"
PLUGIN_HOOK="$(cd ../../../../hooks && pwd -P)/standards-preamble.js"
assert_file "$ASSET_HOOK" "the asset copy of the hook exists"
assert_file "$PLUGIN_HOOK" "the plugin copy of the hook exists"

TMPROOT=$(mktemp -d)
trap 'rm -rf "$TMPROOT"' EXIT
TMPROOT=$(cd "$TMPROOT" && pwd -P)

REPO="$TMPROOT/repo"
mkdir -p "$REPO/.claude"
printf '# readme\n' > "$REPO/README.md"

HEADING='## Repository standards (.claude/standards.json)'
PREAMBLE_TEXT=$'# House rules\n\nRun every check before the stamp.\n  Indented line kept verbatim.\n'
printf '%s' "$PREAMBLE_TEXT" > "$REPO/.claude/standards-preamble.md"

WITH_PREAMBLE='{
  "version": 1,
  "checks": [
    { "name": "lint", "command": "make lint" },
    { "name": "typecheck", "command": "make typecheck" },
    { "name": "test", "command": "make test" }
  ],
  "rules": [ { "doc": "README.md", "check": "lint" } ],
  "preamble": ".claude/standards-preamble.md"
}'
NO_PREAMBLE='{
  "version": 1,
  "checks": [
    { "name": "lint", "command": "make lint" },
    { "name": "test", "command": "make test" }
  ]
}'
MISSING_PREAMBLE='{
  "version": 1,
  "checks": [ { "name": "test", "command": "make test" } ],
  "preamble": ".claude/no-such-preamble.md"
}'
UNPARSABLE='{ "version": 1, "checks": [ { "name": "test", '

# run_hook <hook> -> sets EXIT, OUT, ERR. CLAUDE_PROJECT_DIR names the repo and
# the hook runs from outside it, as an installed hook may.
run_hook() {
  OUT=$(cd "$TMPROOT" && CLAUDE_PROJECT_DIR="$REPO" node "$1" </dev/null 2>"$TMPROOT/stderr")
  EXIT=$?
  ERR=$(cat "$TMPROOT/stderr")
}
# run_hook_cwd <hook> -> the same, with no CLAUDE_PROJECT_DIR, run from the repo.
run_hook_cwd() {
  OUT=$(cd "$REPO" && env -u CLAUDE_PROJECT_DIR node "$1" </dev/null 2>"$TMPROOT/stderr")
  EXIT=$?
  ERR=$(cat "$TMPROOT/stderr")
}
line_count() { [ -z "$1" ] && echo 0 || printf '%s\n' "$1" | wc -l | tr -d ' '; }

EXPECT_WITH="$HEADING
- lint: make lint
- typecheck: make typecheck
- test: make test

$PREAMBLE_TEXT"
# $(...) strips trailing newlines from OUT; strip them from the expectation too.
EXPECT_WITH=$(printf '%s' "$EXPECT_WITH")
EXPECT_NO="$HEADING
- lint: make lint
- test: make test"

for copy in asset plugin; do
  [ "$copy" = asset ] && HOOK="$ASSET_HOOK" || HOOK="$PLUGIN_HOOK"

  # --- no manifest: silent ----------------------------------------------------
  rm -f "$REPO/.claude/standards.json"
  run_hook "$HOOK"
  assert_eq 0 "$EXIT" "$copy/no manifest: exit 0"
  assert_empty "$OUT" "$copy/no manifest: stdout empty"
  assert_empty "$ERR" "$copy/no manifest: stderr empty"

  # --- manifest with preamble: heading, checks, preamble, in order ------------
  printf '%s\n' "$WITH_PREAMBLE" > "$REPO/.claude/standards.json"
  run_hook "$HOOK"
  assert_eq 0 "$EXIT" "$copy/with preamble: exit 0"
  assert_eq "$EXPECT_WITH" "$OUT" "$copy/with preamble: heading, every check, preamble text, in order"
  assert_empty "$ERR" "$copy/with preamble: stderr empty"

  # --- the cwd is the root when CLAUDE_PROJECT_DIR is unset -------------------
  run_hook_cwd "$HOOK"
  assert_eq 0 "$EXIT" "$copy/cwd root: exit 0"
  assert_eq "$EXPECT_WITH" "$OUT" "$copy/cwd root: the manifest is found from the cwd"

  # --- manifest without a preamble key: heading and checks only ---------------
  printf '%s\n' "$NO_PREAMBLE" > "$REPO/.claude/standards.json"
  run_hook "$HOOK"
  assert_eq 0 "$EXIT" "$copy/no preamble key: exit 0"
  assert_eq "$EXPECT_NO" "$OUT" "$copy/no preamble key: heading and checks only"
  assert_empty "$ERR" "$copy/no preamble key: stderr empty"

  # --- manifest naming a missing preamble file: loud, silent stdout, exit 0 ---
  printf '%s\n' "$MISSING_PREAMBLE" > "$REPO/.claude/standards.json"
  run_hook "$HOOK"
  assert_eq 0 "$EXIT" "$copy/missing preamble: exit 0"
  assert_empty "$OUT" "$copy/missing preamble: stdout empty"
  assert_contains "$ERR" "standards-preamble" "$copy/missing preamble: stderr names the hook"
  assert_contains "$ERR" ".claude/no-such-preamble.md" "$copy/missing preamble: stderr names the file"
  assert_eq 1 "$(line_count "$ERR")" "$copy/missing preamble: one stderr line"

  # --- unparsable manifest: loud, silent stdout, exit 0 -----------------------
  printf '%s\n' "$UNPARSABLE" > "$REPO/.claude/standards.json"
  run_hook "$HOOK"
  assert_eq 0 "$EXIT" "$copy/unparsable: exit 0"
  assert_empty "$OUT" "$copy/unparsable: stdout empty"
  assert_contains "$ERR" "standards-preamble" "$copy/unparsable: stderr names the hook"
  assert_contains "$ERR" "standards.json" "$copy/unparsable: stderr names the manifest"
  assert_eq 1 "$(line_count "$ERR")" "$copy/unparsable: one stderr line"
done

finish
