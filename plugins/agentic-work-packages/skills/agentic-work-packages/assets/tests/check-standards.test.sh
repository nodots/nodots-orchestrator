#!/usr/bin/env bash
# Fixture test for check-standards.js (S0.1).
#
# Each fixture under fixtures/standards/ is one JSON file:
#   files     the repo's tracked file list
#   manifest  the .claude/standards.json to validate
#   expect    (invalid-* and warn-*) the defect or warning stderr must carry
#
# Every fixture is materialized as a throwaway git repo — the listed files are
# created and `git add`ed, the manifest is written to .claude/standards.json —
# and the CLI is run against it, so the file list comes from `git ls-files`
# exactly as it does for a real target.
set -uo pipefail
cd "$(dirname "$0")"
. ./lib.sh

SCRIPT="$(cd ../scripts && pwd -P)/check-standards.js"
FIX="$(pwd -P)/fixtures/standards"
MANIFEST=.claude/standards.json
assert_file "$SCRIPT" "check-standards.js exists"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

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

# every line of <text> must start with <prefix>
all_lines_start() {
  local text=$1 prefix=$2 line
  while IFS= read -r line; do
    case "$line" in "$prefix"*) ;; *) return 1 ;; esac
  done <<< "$text"
  return 0
}

# --- the valid fixture --------------------------------------------------------
materialize "$FIX/valid.json" "$TMP/valid"
node "$SCRIPT" --root "$TMP/valid" > "$TMP/valid.out" 2> "$TMP/valid.err"
assert_eq 0 "$?" "valid: exits 0"
assert_empty "$(cat "$TMP/valid.err")" "valid: nothing on stderr"
assert_empty "$(cat "$TMP/valid.out")" "valid: nothing on stdout without --json"

node "$SCRIPT" --root "$TMP/valid" --json > "$TMP/valid.json" 2> "$TMP/valid.err"
assert_eq 0 "$?" "valid --json: exits 0"
assert_eq 1 "$(field "$TMP/valid.json" 'd.version')" "valid --json: prints parseable JSON with version 1"
assert_eq "version,checks,rules,preamble,plugins" "$(field "$TMP/valid.json" 'Object.keys(d).join()')" \
  "valid --json: top-level keys in canonical order"
assert_eq "doc,paths,check" "$(field "$TMP/valid.json" 'Object.keys(d.rules[1]).join()')" \
  "valid --json: rule keys in canonical order"
assert_eq "null" "$(field "$TMP/valid.json" 'JSON.stringify(d.rules[1].paths)')" \
  "valid --json: a rule with no paths normalizes to paths null"
assert_eq "lint,type-check,test" "$(field "$TMP/valid.json" 'd.checks.map(c => c.name).join()')" \
  "valid --json: checks kept in manifest order"

# An explicit manifest argument, relative to --root, reads the same file.
node "$SCRIPT" --root "$TMP/valid" "$MANIFEST" > /dev/null 2>&1
assert_eq 0 "$?" "valid: an explicit manifest path is accepted"

# --- a minimal manifest normalizes the optional fields ------------------------
mkdir -p "$TMP/minimal"
git_q init -q "$TMP/minimal"
mkdir -p "$TMP/minimal/.claude"
printf '{"version":1,"checks":[{"name":"test","command":"make test"}],"rules":[]}\n' > "$TMP/minimal/$MANIFEST"
node "$SCRIPT" --root "$TMP/minimal" --json > "$TMP/minimal.json" 2> "$TMP/minimal.err"
assert_eq 0 "$?" "minimal: an empty rules array is valid"
assert_eq "null" "$(field "$TMP/minimal.json" 'JSON.stringify(d.preamble)')" "minimal: absent preamble normalizes to null"
assert_eq "[]" "$(field "$TMP/minimal.json" 'JSON.stringify(d.plugins)')" "minimal: absent plugins normalizes to []"

# --- the check: null warning --------------------------------------------------
fx="$FIX/warn-null-check.json"
materialize "$fx" "$TMP/warn"
node "$SCRIPT" --root "$TMP/warn" > "$TMP/warn.out" 2> "$TMP/warn.err"
assert_eq 0 "$?" "warn-null-check: exit stays 0"
assert_eq "$(field "$fx" 'd.expect')" "$(cat "$TMP/warn.err")" "warn-null-check: the warning is the one stderr line"

# --- every invalid fixture ----------------------------------------------------
n_invalid=0
for fx in "$FIX"/invalid-*.json; do
  n_invalid=$((n_invalid + 1))
  name=$(basename "$fx" .json)
  materialize "$fx" "$TMP/$name"
  node "$SCRIPT" --root "$TMP/$name" --json > "$TMP/$name.out" 2> "$TMP/$name.err"
  rc=$?
  err=$(cat "$TMP/$name.err")
  assert_eq 2 "$rc" "$name: exits 2"
  assert_eq "standards: $MANIFEST: $(field "$fx" 'd.expect')" "$err" "$name: stderr is exactly its defect, one line"
  assert_empty "$(cat "$TMP/$name.out")" "$name: --json prints nothing on failure"
done
assert_eq 14 "$n_invalid" "all fourteen invalid fixtures were found (unknown key at four levels)"

# --- several defects: one line each, all in the standards: <path>: shape -------
mkdir -p "$TMP/multi/.claude"
git_q init -q "$TMP/multi"
printf '{"version":"1","checks":[{"name":"a","command":""},{"name":"a","command":"x","extra":1}],"rules":[{"doc":"NOPE.md","check":"zz"}],"plugins":[{"name":"p","marketplace":"bad market"}],"stray":true}\n' \
  > "$TMP/multi/$MANIFEST"
node "$SCRIPT" --root "$TMP/multi" > /dev/null 2> "$TMP/multi.err"
assert_eq 2 "$?" "multi: exits 2"
err=$(cat "$TMP/multi.err")
assert_eq 8 "$(printf '%s\n' "$err" | wc -l | tr -d ' ')" "multi: one stderr line per defect (8 defects)"
if all_lines_start "$err" "standards: $MANIFEST: "; then _pass "multi: every line is shaped standards: <path>: <defect>"
else _fail "multi: every line is shaped standards: <path>: <defect>" "$err"; fi
for d in 'version: must be the integer 1' 'checks[0].command: must be a non-empty string' \
         'checks[1].name: "a" is not unique' 'checks[1].extra: unknown key' \
         'rules[0].doc: "NOPE.md" is not a tracked file' 'rules[0].check: "zz" names no check' \
         'plugins[0].marketplace: "bad market" must match ^[A-Za-z0-9_.-]+$' 'stray: unknown key'; do
  assert_contains "$err" "standards: $MANIFEST: $d" "multi: names [$d]"
done

# --- missing and unparsable files ---------------------------------------------
mkdir -p "$TMP/missing"
git_q init -q "$TMP/missing"
node "$SCRIPT" --root "$TMP/missing" > /dev/null 2> "$TMP/missing.err"
assert_eq 2 "$?" "missing manifest: exits 2"
assert_eq "standards: $MANIFEST: file not found" "$(cat "$TMP/missing.err")" "missing manifest: names the missing file"

mkdir -p "$TMP/broken/.claude"
git_q init -q "$TMP/broken"
printf '{"version": 1,\n' > "$TMP/broken/$MANIFEST"
node "$SCRIPT" --root "$TMP/broken" > /dev/null 2> "$TMP/broken.err"
assert_eq 2 "$?" "unparsable manifest: exits 2"
err=$(cat "$TMP/broken.err")
assert_contains "$err" "standards: $MANIFEST: not valid JSON" "unparsable manifest: names the unparsable file"
assert_eq 1 "$(printf '%s\n' "$err" | wc -l | tr -d ' ')" "unparsable manifest: one stderr line"

# --- validateFile against a committed and an untracked manifest ---------------
repo="$TMP/vf"
materialize "$FIX/valid.json" "$repo"
git_q -C "$repo" commit -q -m fixture
out=$(node -e '
  const { validateFile } = require(process.argv[1]);
  const r = validateFile(process.argv[2]);
  process.stdout.write(JSON.stringify({ ok: r.ok, defects: r.defects, warnings: r.warnings, v: r.manifest && r.manifest.version }));
' "$SCRIPT" "$repo")
assert_eq '{"ok":true,"defects":[],"warnings":[],"v":1}' "$out" "validateFile: committed manifest is valid"
node "$SCRIPT" --root "$repo" > /dev/null 2>&1
assert_eq 0 "$?" "validateFile repo: CLI exits 0 with the manifest committed"

# Untrack the manifest and add a rule whose doc exists on disk but is not tracked.
git_q -C "$repo" rm -q --cached "$MANIFEST"
printf '# untracked\n' > "$repo/UNTRACKED.md"
node -e '
  const fs = require("fs"), p = process.argv[1];
  const m = JSON.parse(fs.readFileSync(p, "utf8"));
  m.rules.push({ doc: "UNTRACKED.md", check: "lint" });
  fs.writeFileSync(p, JSON.stringify(m, null, 2) + "\n");
' "$repo/$MANIFEST"
assert_eq "" "$(git -C "$repo" ls-files -- "$MANIFEST" UNTRACKED.md)" "validateFile repo: manifest and new doc are untracked"
out=$(node -e '
  const { validateFile } = require(process.argv[1]);
  const r = validateFile(process.argv[2]);
  process.stdout.write(JSON.stringify({ ok: r.ok, defects: r.defects, n: r.manifest ? r.manifest.rules.length : -1 }));
' "$SCRIPT" "$repo")
assert_eq '{"ok":false,"defects":["rules[3].doc: \"UNTRACKED.md\" is not a tracked file"],"n":4}' "$out" \
  "validateFile: an untracked manifest is still read, and its doc is judged against tracked files only"
node "$SCRIPT" --root "$repo" > /dev/null 2> "$TMP/vf.err"
assert_eq 2 "$?" "validateFile repo: CLI exits 2 for the untracked doc"
assert_eq "standards: $MANIFEST: rules[3].doc: \"UNTRACKED.md\" is not a tracked file" "$(cat "$TMP/vf.err")" \
  "validateFile repo: CLI names the untracked doc"

# A root that is not a git repo has no tracked file list: refused, named.
mkdir -p "$TMP/nogit/.claude"
printf '{"version":1,"checks":[{"name":"test","command":"make test"}],"rules":[]}\n' > "$TMP/nogit/$MANIFEST"
GIT_CEILING_DIRECTORIES="$TMP" node "$SCRIPT" --root "$TMP/nogit" > /dev/null 2> "$TMP/nogit.err"
assert_eq 2 "$?" "not a git repo: exits 2"
assert_contains "$(cat "$TMP/nogit.err")" "standards: $MANIFEST: cannot list tracked files" "not a git repo: says why"

# --- validateStandards is pure: text and files in, result out -----------------
out=$(node -e '
  const { validateStandards } = require(process.argv[1]);
  const files = ["a/b/c.js", "top.js", "D.md"];
  const text = JSON.stringify({ version: 1, checks: [{ name: "t", command: "x" }], rules: [
    { doc: "D.md", paths: ["a/*.js"], check: "t" },
    { doc: "D.md", paths: ["**/c.js", "*.js", "a/**"], check: null },
  ] });
  const r = validateStandards({ text, files });
  process.stdout.write(JSON.stringify({ ok: r.ok, defects: r.defects, warnings: r.warnings }));
' "$SCRIPT")
assert_eq '{"ok":false,"defects":["rules[0].paths[0]: \"a/*.js\" matches no tracked file"],"warnings":["D.md: rule has no check"]}' \
  "$out" "validateStandards: * stays within one segment, ** spans any depth, warnings returned"

out=$(node -e '
  const { validateStandards } = require(process.argv[1]);
  const r = validateStandards({ text: "[]", files: [] });
  process.stdout.write(JSON.stringify({ ok: r.ok, manifest: r.manifest, defects: r.defects }));
' "$SCRIPT")
assert_eq '{"ok":false,"manifest":null,"defects":["manifest: must be a JSON object"]}' "$out" \
  "validateStandards: a non-object manifest is a defect and yields no manifest"

out=$(node -e '
  const fs = require("fs");
  const { validateStandards } = require(process.argv[1]);
  const files = JSON.parse(fs.readFileSync(process.argv[2], "utf8")).files;
  const r = validateStandards({ text: fs.readFileSync(process.argv[3], "utf8"), files });
  process.stdout.write(JSON.stringify({ ok: r.ok, defects: r.defects }));
' "$SCRIPT" "$FIX/valid.json" "$TMP/valid.json")
assert_eq '{"ok":true,"defects":[]}' "$out" "validateStandards: the normalized manifest is itself valid"

finish
