#!/usr/bin/env bash
# SV0 gate: the phase-0 standards pieces agree before anything is built on them.
#
#   1. The valid fixture: the validator exits 0, and both copies of the
#      standards-preamble hook print the heading, every check and the preamble,
#      in order.
#   2. Every invalid fixture: the validator exits 2 and names the defect.
#   3. This repository's own .claude/standards.json validates against its own
#      tracked files, and every #fragment doc names a real heading.
#   4. No orchestrator text outside tests names a tool or command that is not
#      the target repo's, and the worker contract names none at all.
#   5. The contract asset and this repo's installed copy are identical.
#
# The gate edits nothing it verifies: it reads the implementation, the text and
# the fixtures, and writes only to a temp directory.
set -uo pipefail
cd "$(dirname "$0")"
. ./lib.sh

SCRIPT="$(cd ../scripts && pwd -P)/check-standards.js"
ASSET_HOOK="$(cd ../hooks && pwd -P)/standards-preamble.js"
PLUGIN_HOOK="$(cd ../../../../hooks && pwd -P)/standards-preamble.js"
FIX="$(pwd -P)/fixtures/standards"
ROOT="$(cd ../../../../../.. && pwd -P)"
MANIFEST=.claude/standards.json
CONTRACT_ASSET=plugins/agentic-work-packages/skills/agentic-work-packages/assets/worker-contract.md

assert_file "$SCRIPT" "the validator exists"
assert_file "$ASSET_HOOK" "the asset copy of the hook exists"
assert_file "$PLUGIN_HOOK" "the plugin copy of the hook exists"
assert_file "$ROOT/$MANIFEST" "this repository has a manifest"
assert_file "$ROOT/$CONTRACT_ASSET" "the contract asset exists"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
TMP=$(cd "$TMP" && pwd -P)

git_q() { git -c user.name=fixture -c user.email=fixture@example.invalid -c commit.gpgsign=false "$@"; }

# field <fixture.json> <node expression over `d`>
field() { node -e '
  const d = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
  const v = eval(process.argv[2]);
  process.stdout.write(v === undefined ? "" : String(v));
' "$1" "$2"; }

# materialize <fixture.json> <dir> — a git repo with the fixture's files tracked
# and its manifest written (and tracked) at .claude/standards.json.
materialize() {
  local fx=$1 dir=$2
  mkdir -p "$dir"
  git_q init -q "$dir"
  node -e '
    const fs = require("fs"), path = require("path");
    const d = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    const root = process.argv[2];
    for (const f of d.files) {
      fs.mkdirSync(path.dirname(path.join(root, f)), { recursive: true });
      fs.writeFileSync(path.join(root, f), "# " + f + "\n");
    }
    fs.mkdirSync(path.join(root, ".claude"), { recursive: true });
    fs.writeFileSync(path.join(root, ".claude/standards.json"), JSON.stringify(d.manifest, null, 2) + "\n");
  ' "$fx" "$dir"
  git_q -C "$dir" add -A
}

# --- 1. the valid fixture: validator accepts, both hooks print it -------------
VALID="$TMP/valid"
materialize "$FIX/valid.json" "$VALID"
PREAMBLE_REL=$(field "$FIX/valid.json" 'd.manifest.preamble')
assert_nonempty "$PREAMBLE_REL" "valid: the fixture names a preamble"
PREAMBLE_TEXT=$'# Fixture preamble\n\nEvery check runs before the stamp.\n'
printf '%s' "$PREAMBLE_TEXT" > "$VALID/$PREAMBLE_REL"

node "$SCRIPT" --root "$VALID" > "$TMP/valid.out" 2> "$TMP/valid.err"
assert_eq 0 "$?" "valid: the validator exits 0"
assert_empty "$(cat "$TMP/valid.err")" "valid: the validator prints nothing on stderr"

# The expected hook output, built from the fixture rather than restated.
CHECK_LINES=$(field "$FIX/valid.json" 'd.manifest.checks.map(c => "- " + c.name + ": " + c.command).join("\n")')
assert_eq 3 "$(printf '%s\n' "$CHECK_LINES" | wc -l | tr -d ' ')" "valid: the fixture has three checks"
EXPECT="## Repository standards (.claude/standards.json)
$CHECK_LINES

$PREAMBLE_TEXT"
# $(...) strips trailing newlines from the hook output; strip them here too.
EXPECT=$(printf '%s' "$EXPECT")

for copy in asset plugin; do
  [ "$copy" = asset ] && HOOK="$ASSET_HOOK" || HOOK="$PLUGIN_HOOK"
  OUT=$(cd "$TMP" && CLAUDE_PROJECT_DIR="$VALID" node "$HOOK" </dev/null 2>"$TMP/hook.err")
  rc=$?
  assert_eq 0 "$rc" "valid/$copy hook: exit 0"
  assert_eq "$EXPECT" "$OUT" "valid/$copy hook: heading, every check, preamble, in order"
  assert_empty "$(cat "$TMP/hook.err")" "valid/$copy hook: stderr empty"
done

# --- 2. every invalid fixture: validator exits 2 naming the defect ------------
n_invalid=0
for fx in "$FIX"/invalid-*.json; do
  [ -f "$fx" ] || continue
  n_invalid=$((n_invalid + 1))
  name=$(basename "$fx" .json)
  expect=$(field "$fx" 'd.expect')
  assert_nonempty "$expect" "$name: the fixture names its defect"
  materialize "$fx" "$TMP/$name"
  node "$SCRIPT" --root "$TMP/$name" > "$TMP/$name.out" 2> "$TMP/$name.err"
  assert_eq 2 "$?" "$name: the validator exits 2"
  assert_contains "$(cat "$TMP/$name.err")" "standards: $MANIFEST: $expect" "$name: stderr names the defect"
done
assert_ne 0 "$n_invalid" "invalid fixtures were found"

# --- 3. this repository's manifest validates and its fragments resolve --------
node "$SCRIPT" --root "$ROOT" > "$TMP/own.out" 2> "$TMP/own.err"
assert_eq 0 "$?" "own manifest: the validator exits 0 with --root <repo root>"
# Warnings for a rule with no check are allowed; anything else on stderr is not.
own_err=$(grep -v ': rule has no check$' "$TMP/own.err")
assert_empty "$own_err" "own manifest: stderr carries no defect"

# Every rule doc with a #fragment: the fragment is the slug of a heading in the
# file (lowercase, punctuation dropped, spaces to hyphens), outside code fences.
frag_report=$(node -e '
  const fs = require("fs"), path = require("path");
  const root = process.argv[1];
  const m = JSON.parse(fs.readFileSync(path.join(root, ".claude/standards.json"), "utf8"));
  const slug = (h) => h.trim().toLowerCase().replace(/[^a-z0-9 _-]/g, "").replace(/ /g, "-");
  for (const r of m.rules) {
    const i = r.doc.indexOf("#");
    if (i === -1) continue;
    const file = r.doc.slice(0, i), frag = r.doc.slice(i + 1);
    const slugs = [];
    let fenced = false;
    for (const line of fs.readFileSync(path.join(root, file), "utf8").split("\n")) {
      if (/^\s*(```|~~~)/.test(line)) { fenced = !fenced; continue; }
      const h = !fenced && /^#{1,6}\s+(.*?)\s*#*\s*$/.exec(line);
      if (h) slugs.push(slug(h[1]));
    }
    console.log((slugs.includes(frag) ? "ok " : "missing ") + r.doc);
  }
' "$ROOT")
assert_nonempty "$frag_report" "own manifest: at least one rule doc carries a #fragment"
while IFS= read -r line; do
  [ -n "$line" ] || continue
  assert_eq "ok ${line#* }" "$line" "own manifest: fragment resolves to a heading (${line#* })"
done <<< "$frag_report"

# --- 4. the text invariant ----------------------------------------------------
grep_out=$(git -C "$ROOT" grep -n -E 'lint passes|npm run|npm test|TypeScript compiles' -- plugins docs ':!*/tests/*' 2>&1)
rc=$?
assert_eq 1 "$rc" "text: git grep ran and matched nothing (exit 1)"
assert_empty "$grep_out" "text: no tool or command name in plugins or docs outside tests"

grep_out=$(grep -n -iE 'lint|typecheck|npm' "$ROOT/$CONTRACT_ASSET" 2>&1)
rc=$?
assert_eq 1 "$rc" "text: grep ran over the contract and matched nothing (exit 1)"
assert_empty "$grep_out" "text: the worker contract names no lint, typecheck or npm"

# --- 5. contract asset and installed copy are identical -----------------------
diff_out=$(diff "$ROOT/$CONTRACT_ASSET" "$ROOT/.claude/worker-contract.md" 2>&1)
rc=$?
assert_eq 0 "$rc" "contract: diff exits 0"
assert_empty "$diff_out" "contract: the asset and .claude/worker-contract.md are identical"

finish
