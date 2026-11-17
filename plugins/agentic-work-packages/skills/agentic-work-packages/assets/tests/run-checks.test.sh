#!/usr/bin/env bash
# Fixture test for run-checks.js (E0.2).
#
# run-checks.js validates the head's .claude/standards.json, then runs the
# checks[] of the *base* ref's manifest, so a PR cannot change what it is
# checked by. Each case below builds a throwaway git repo: a base commit, and
# where the case needs one, a head commit (or working-tree edit) on top of it.
set -uo pipefail
cd "$(dirname "$0")"
. ./lib.sh

SCRIPT="$(cd ../scripts && pwd -P)/run-checks.js"
MANIFEST=.claude/standards.json
assert_file "$SCRIPT" "run-checks.js exists"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

git_q() { git -c user.name=fixture -c user.email=fixture@example.invalid -c commit.gpgsign=false "$@"; }

# manifest <dir> <checks JSON> [<rules JSON>] — write the manifest into <dir>.
manifest() {
  mkdir -p "$1/.claude"
  printf '{"version":1,"checks":%s,"rules":%s}\n' "$2" "${3:-[]}" > "$1/$MANIFEST"
}

# repo <dir> — a fresh git repo with one tracked file and no commits.
repo() {
  mkdir -p "$1"
  git_q init -q "$1"
  printf '# doc\n' > "$1/DOC.md"
  git_q -C "$1" add -A
}

# commit <dir> <message> — commit everything in the working tree.
commit() { git_q -C "$1" add -A && git_q -C "$1" commit -q -m "$2"; }

# run <dir> <name> [args...] — run the script, capture out/err/rc under $TMP/<name>.
run() {
  local dir=$1 name=$2; shift 2
  node "$SCRIPT" --root "$dir" "$@" > "$TMP/$name.out" 2> "$TMP/$name.err"
  echo $? > "$TMP/$name.rc"
}
rc()  { cat "$TMP/$1.rc"; }
out() { cat "$TMP/$1.out"; }
err() { cat "$TMP/$1.err"; }
last_line() { tail -n 1 "$TMP/$1.out"; }

# --- all checks pass -> exit 0 ------------------------------------------------
r="$TMP/pass"; repo "$r"
manifest "$r" '[{"name":"lint","command":"echo lint-ran"},{"name":"test","command":"echo test-ran"}]'
commit "$r" base
run "$r" pass
assert_eq 0 "$(rc pass)" "all pass: exits 0"
assert_contains "$(out pass)" "lint-ran" "all pass: the first check's stdout is passed through"
assert_contains "$(out pass)" "test-ran" "all pass: the second check's stdout is passed through"
assert_contains "$(out pass)" "PASS  lint" "all pass: PASS line for lint"
assert_contains "$(out pass)" "PASS  test" "all pass: PASS line for test"
assert_eq "run-checks: 2 of 2 checks passed (manifest from HEAD)" "$(last_line pass)" \
  "all pass: last line names the tally and the default base HEAD"
assert_eq "lint-ran|PASS  lint|test-ran|PASS  test|run-checks: 2 of 2 checks passed (manifest from HEAD)" \
  "$(out pass | paste -sd '|' -)" "all pass: checks run in manifest order, each followed by its line"
assert_empty "$(err pass)" "all pass: nothing on stderr"

# --- one of two fails -> exit 1, both run, both lines printed -----------------
r="$TMP/onefail"; repo "$r"
manifest "$r" '[{"name":"first","command":"echo first-ran; echo first-err >&2; exit 3"},{"name":"second","command":"echo second-ran"}]'
commit "$r" base
run "$r" onefail
assert_eq 1 "$(rc onefail)" "one of two fails: exits 1"
assert_contains "$(out onefail)" "first-ran" "one of two fails: the failing check ran"
assert_contains "$(err onefail)" "first-err" "one of two fails: the check's stderr is passed through"
assert_contains "$(out onefail)" "FAIL  first (exit 3)" "one of two fails: FAIL line carries the exit code"
assert_contains "$(out onefail)" "second-ran" "one of two fails: the check after the failure still ran"
assert_contains "$(out onefail)" "PASS  second" "one of two fails: PASS line for the second check"
assert_eq "run-checks: 1 of 2 checks passed (manifest from HEAD)" "$(last_line onefail)" "one of two fails: last line"

# --- checks run with cwd <root> -----------------------------------------------
r="$TMP/cwd"; repo "$r"
manifest "$r" '[{"name":"at-root","command":"test -f DOC.md"}]'
commit "$r" base
( cd "$TMP" && node "$SCRIPT" --root "$r" > "$TMP/cwd.out" 2> "$TMP/cwd.err"; echo $? > "$TMP/cwd.rc" )
assert_eq 0 "$(rc cwd)" "cwd: a check sees the root as its working directory"

# --root defaults to the cwd.
( cd "$r" && node "$SCRIPT" > "$TMP/cwddef.out" 2> "$TMP/cwddef.err"; echo $? > "$TMP/cwddef.rc" )
assert_eq 0 "$(rc cwddef)" "cwd: --root defaults to the current directory"
assert_contains "$(out cwddef)" "PASS  at-root" "cwd: the default root runs the check"

# --- head manifest invalid -> exit 2 ------------------------------------------
r="$TMP/headbad"; repo "$r"
manifest "$r" '[{"name":"test","command":"touch ran"}]'
commit "$r" base
printf '{"version":2,"checks":[{"name":"test","command":"touch ran"}],"rules":[]}\n' > "$r/$MANIFEST"
run "$r" headbad
assert_eq 2 "$(rc headbad)" "head invalid: exits 2"
assert_eq "standards: $MANIFEST: version: must be the integer 1" "$(err headbad)" \
  "head invalid: the defect is printed as check-standards.js prints it"
if [ -e "$r/ran" ]; then _fail "head invalid: no check runs"; else _pass "head invalid: no check runs"; fi

# Head manifest missing -> exit 2.
r="$TMP/headgone"; repo "$r"
manifest "$r" '[{"name":"test","command":"true"}]'
commit "$r" base
rm "$r/$MANIFEST"
run "$r" headgone
assert_eq 2 "$(rc headgone)" "head missing: exits 2"
assert_eq "standards: $MANIFEST: file not found" "$(err headgone)" "head missing: names the missing file"

# --- base has no manifest -> exit 2 -------------------------------------------
r="$TMP/basegone"; repo "$r"
commit "$r" base
git_q -C "$r" tag base
manifest "$r" '[{"name":"test","command":"touch ran"}]'
commit "$r" head
run "$r" basegone --base base
assert_eq 2 "$(rc basegone)" "base has no manifest: exits 2"
assert_eq "run-checks: no $MANIFEST at base" "$(err basegone)" "base has no manifest: says so, naming the base"
if [ -e "$r/ran" ]; then _fail "base has no manifest: no check runs"; else _pass "base has no manifest: no check runs"; fi

# --- base manifest invalid -> exit 2 ------------------------------------------
r="$TMP/basebad"; repo "$r"
manifest "$r" '[{"name":"test","command":"touch ran"}]' '[{"doc":"NOPE.md","check":"test"}]'
commit "$r" base
git_q -C "$r" tag base
manifest "$r" '[{"name":"test","command":"touch ran"}]'
commit "$r" head
run "$r" basebad --base base
assert_eq 2 "$(rc basebad)" "base invalid: exits 2"
assert_eq "standards: base:$MANIFEST: rules[0].doc: \"NOPE.md\" is not a tracked file" "$(err basebad)" \
  "base invalid: the defect is named against the base"
if [ -e "$r/ran" ]; then _fail "base invalid: no check runs"; else _pass "base invalid: no check runs"; fi

# The base's tracked file list comes from the base tree, not the head's.
r="$TMP/basetree"; repo "$r"
manifest "$r" '[{"name":"test","command":"true"}]' '[{"doc":"LATER.md","check":"test"}]'
commit "$r" base
git_q -C "$r" tag base
printf '# later\n' > "$r/LATER.md"
commit "$r" head
run "$r" basetree --base base
assert_eq 2 "$(rc basetree)" "base tree: a doc added only at the head does not satisfy the base manifest"
assert_eq "standards: base:$MANIFEST: rules[0].doc: \"LATER.md\" is not a tracked file" "$(err basetree)" \
  "base tree: names the doc missing from the base tree"

# --- an unresolvable base is refused, not read as "no manifest" ----------------
r="$TMP/noref"; repo "$r"
manifest "$r" '[{"name":"test","command":"true"}]'
commit "$r" base
run "$r" noref --base no-such-ref
assert_eq 2 "$(rc noref)" "unresolvable base: exits 2"
assert_eq "run-checks: cannot resolve base no-such-ref" "$(err noref)" "unresolvable base: says so"

# --- the head rewrites a check's command: the base's command runs -------------
r="$TMP/rewrite"; repo "$r"
manifest "$r" '[{"name":"test","command":"false"}]'
commit "$r" base
git_q -C "$r" tag base
manifest "$r" '[{"name":"test","command":"true"}]'
commit "$r" head
run "$r" rewrite --base base
assert_eq 1 "$(rc rewrite)" "head rewrites false to true: exits 1, the base command ran"
assert_contains "$(out rewrite)" "FAIL  test (exit 1)" "head rewrites: FAIL line for the base command"
assert_eq "run-checks: 0 of 1 checks passed (manifest from base)" "$(last_line rewrite)" \
  "head rewrites: last line names the base"

# Uncommitted head edits are the head too: the working tree cannot change the command.
r="$TMP/rewrite-wt"; repo "$r"
manifest "$r" '[{"name":"test","command":"false"}]'
commit "$r" base
manifest "$r" '[{"name":"test","command":"true"}]'
run "$r" rewrite-wt
assert_eq 1 "$(rc rewrite-wt)" "working-tree rewrite against base HEAD: exits 1"

# --- the head adds a check the base does not have: it does not run ------------
r="$TMP/added"; repo "$r"
manifest "$r" '[{"name":"test","command":"true"}]'
commit "$r" base
git_q -C "$r" tag base
manifest "$r" '[{"name":"test","command":"true"},{"name":"sneak","command":"touch sneaked"}]'
commit "$r" head
run "$r" added --base base
assert_eq 0 "$(rc added)" "head adds a check: exits 0 on the base's checks"
if [ -e "$r/sneaked" ]; then _fail "head adds a check: the added check did not run"
else _pass "head adds a check: the added check did not run"; fi
assert_not_contains "$(out added)" "sneak" "head adds a check: no line names it"
assert_eq "run-checks: 1 of 1 checks passed (manifest from base)" "$(last_line added)" "head adds a check: tally is the base's"

# --- warnings go to stderr and never change the exit code ---------------------
r="$TMP/warn"; repo "$r"
manifest "$r" '[{"name":"test","command":"true"}]' '[{"doc":"DOC.md","check":null}]'
commit "$r" base
run "$r" warn
assert_eq 0 "$(rc warn)" "warnings: exit stays 0"
assert_contains "$(err warn)" "standards: DOC.md: rule has no check" "warnings: the head's warning is on stderr"
assert_contains "$(err warn)" "standards: HEAD:$MANIFEST: DOC.md: rule has no check" "warnings: the base's warning is on stderr"
assert_not_contains "$(out warn)" "rule has no check" "warnings: nothing on stdout"

r="$TMP/warnfail"; repo "$r"
manifest "$r" '[{"name":"test","command":"false"}]' '[{"doc":"DOC.md","check":null}]'
commit "$r" base
run "$r" warnfail
assert_eq 1 "$(rc warnfail)" "warnings: a failing check still exits 1"

# --- usage --------------------------------------------------------------------
run "$TMP/pass" usage --bogus
assert_eq 2 "$(rc usage)" "usage: an unknown flag exits 2"
assert_contains "$(err usage)" "run-checks: usage:" "usage: says how to call it"

finish
