#!/usr/bin/env bash
# V0 gate: scripts/test.sh, run against a temporary copy of this repository,
# exits 0 on the copy as it stands and non-zero once a syntax error or a
# credential is seeded into it. The seeded secret is built at runtime from
# fragments, so this file holds no literal that trips the credential scan.
#
# The copy is a fresh git repo: branch "base" holds the tree, HEAD is on "work",
# and each defect is committed on "work", so the credential check sees it as a
# changed file (BASE_REF=base). This file is left out of the copy; otherwise the
# copy's test.sh would run it again, without end.
set -uo pipefail
cd "$(dirname "$0")"
. ../../plugins/fleet/tests/lib.sh

ROOT="$(cd ../.. && pwd -P)"
SELF="scripts/tests/$(basename "$0")"
assert_file "$ROOT/scripts/test.sh" "scripts/test.sh exists"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
TMP=$(cd "$TMP" && pwd -P)

# Secret fragment, joined only at runtime.
AWS_ID="AK""IA""$(printf 'Q7W2E9R4T6Y1U3I8')"

# Tracked and untracked files of the working tree, minus ignored files and this test.
BASE="$TMP/base"
mkdir -p "$BASE"
(
  cd "$ROOT" || exit 1
  git ls-files -co --exclude-standard | while IFS= read -r f; do
    [ -f "$f" ] && [ "$f" != "$SELF" ] && printf '%s\n' "$f"
  done | tar -cf - -T - | tar -xf - -C "$BASE"
)
(
  cd "$BASE" || exit 1
  git init -q -b base .
  git config user.email t@example.com
  git config user.name t
  git config commit.gpgsign false
  git add -A
  git commit -q -m base
  git checkout -q -b work
)
assert_file "$BASE/scripts/test.sh" "the copy holds scripts/test.sh"

# copy <name> — a fresh clone of the base copy, git history included.
copy() { cp -R "$BASE" "$TMP/$1"; echo "$TMP/$1"; }

# seed <tree> <path> <content> — commit a file holding <content> on "work".
seed() {
  mkdir -p "$(dirname "$1/$2")"
  printf '%s\n' "$3" > "$1/$2"
  (cd "$1" && git add -- "$2" && git commit -q -m "seed $2")
}

run_in() { OUT=$(cd "$1" && BASE_REF=base bash scripts/test.sh 2>&1); RC=$?; }

T=$(copy clean)
run_in "$T"
assert_eq "0" "$RC" "clean copy: test.sh exits 0"
assert_contains "$OUT" "ALL PASS" "clean copy: test.sh prints ALL PASS"

T=$(copy syntax-sh)
seed "$T" plugins/v0-seed/broken.sh 'if then fi'
run_in "$T"
assert_ne "0" "$RC" "seeded .sh syntax error: test.sh exits non-zero"
assert_contains "$OUT" "FAIL  plugins/v0-seed/broken.sh (bash -n)" "seeded .sh syntax error: the file is named"

T=$(copy syntax-js)
seed "$T" plugins/v0-seed/broken.js 'function ( {'
run_in "$T"
assert_ne "0" "$RC" "seeded .js syntax error: test.sh exits non-zero"
assert_contains "$OUT" "FAIL  plugins/v0-seed/broken.js (node --check)" "seeded .js syntax error: the file is named"

T=$(copy credential)
seed "$T" v0-seed/aws.env "id=$AWS_ID"
run_in "$T"
assert_ne "0" "$RC" "seeded credential: test.sh exits non-zero"
assert_contains "$OUT" "FAIL  v0-seed/aws.env" "seeded credential: the file is named"
assert_not_contains "$OUT" "$AWS_ID" "seeded credential: the secret is not echoed"

finish
