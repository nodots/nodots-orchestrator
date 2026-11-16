#!/usr/bin/env bash
# Fixture test for scripts/check-secrets.sh: the gitleaks archive is checked
# against the pinned SHA-256 before anything runs, and a secret added in one
# commit and removed in a later one fails the range, naming the commit, the
# file and the rule but never the secret.
#
# The scan checks need the real gitleaks archive. GITLEAKS_ARCHIVE names a local
# copy; without one the test downloads it once. With neither, the scan checks
# are skipped and the tally line says so. The checksum checks always run.
#
# The seeded token is built at runtime, so this file holds no literal secret.
set -uo pipefail
cd "$(dirname "$0")"
. ../../plugins/fleet/tests/lib.sh

SCRIPT="$(cd .. && pwd -P)/check-secrets.sh"
assert_file "$SCRIPT" "scripts/check-secrets.sh exists"

PINNED_VERSION=8.30.1
PINNED_SHA256=551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb
URL="https://github.com/gitleaks/gitleaks/releases/download/v$PINNED_VERSION/gitleaks_${PINNED_VERSION}_linux_x64.tar.gz"

body=$(cat "$SCRIPT" 2>/dev/null)
assert_contains "$body" "$PINNED_VERSION" "the script pins gitleaks $PINNED_VERSION"
assert_contains "$body" "$PINNED_SHA256" "the script pins the archive's SHA-256"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
TMP=$(cd "$TMP" && pwd -P)

# repo <name> — a git repo with one clean commit, tagged "base".
repo() {
  local d="$TMP/$1"
  mkdir -p "$d"
  (
    cd "$d" || exit 1
    git init -q -b main .
    git config user.email t@example.com
    git config user.name t
    echo 'clean' > clean.txt
    git add clean.txt
    git commit -q -m base
    git tag base
  )
  echo "$d"
}

# run_scan <repo> <archive> <base> <head>
run_scan() { OUT=$(cd "$1" && GITLEAKS_ARCHIVE="$2" bash "$SCRIPT" "$3" "$4" 2>&1); RC=$?; }

# A checksum mismatch fails before anything in the archive runs. The fake
# archive holds a "gitleaks" that leaves a marker if it is ever executed.
T=$(repo mismatch-fake)
mkdir -p "$TMP/fake"
printf '#!/bin/sh\ntouch "%s/ran"\n' "$TMP" > "$TMP/fake/gitleaks"
chmod +x "$TMP/fake/gitleaks"
tar -czf "$TMP/fake.tar.gz" -C "$TMP/fake" gitleaks
run_scan "$T" "$TMP/fake.tar.gz" base HEAD
assert_ne "0" "$RC" "an archive with the wrong SHA-256 fails"
assert_contains "$OUT" "SHA-256 mismatch" "the failure names the checksum mismatch"
assert_eq "absent" "$([ -e "$TMP/ran" ] && echo present || echo absent)" "nothing in a mismatched archive runs"

T=$(repo missing-archive)
run_scan "$T" "$TMP/no-such-archive.tar.gz" base HEAD
assert_ne "0" "$RC" "a GITLEAKS_ARCHIVE that does not exist fails rather than downloading"
assert_contains "$OUT" "no-such-archive.tar.gz" "the missing archive is named"

# The real archive, for the scan checks.
ARCHIVE=""
SKIP_REASON=""
if [ -n "${GITLEAKS_ARCHIVE:-}" ] && [ -f "$GITLEAKS_ARCHIVE" ]; then
  ARCHIVE="$GITLEAKS_ARCHIVE"
elif curl -fsSL --max-time 60 -o "$TMP/gitleaks.tar.gz" "$URL" 2>/dev/null; then
  ARCHIVE="$TMP/gitleaks.tar.gz"
else
  SKIP_REASON="no GITLEAKS_ARCHIVE file and no network to download gitleaks $PINNED_VERSION"
  echo "  SKIP  scan checks: $SKIP_REASON"
fi

if [ -n "$ARCHIVE" ]; then
  # A copy of the real archive with one byte changed.
  cp "$ARCHIVE" "$TMP/tampered.tar.gz"
  printf '\x00' | dd of="$TMP/tampered.tar.gz" bs=1 seek=100 count=1 conv=notrunc 2>/dev/null
  T=$(repo mismatch-real)
  run_scan "$T" "$TMP/tampered.tar.gz" base HEAD
  assert_ne "0" "$RC" "the real archive with one byte changed fails"
  assert_contains "$OUT" "SHA-256 mismatch" "the one-byte change is reported as a checksum mismatch"
  assert_not_contains "$OUT" "with gitleaks $PINNED_VERSION" "no scan starts after a mismatch"

  T=$(repo clean-range)
  (cd "$T" && echo 'more clean text' > notes.txt && git add notes.txt && git commit -q -m clean)
  run_scan "$T" "$ARCHIVE" base HEAD
  assert_eq "0" "$RC" "a clean range passes"
  assert_contains "$OUT" "with gitleaks $PINNED_VERSION" "the clean range was scanned"

  # A GitHub token shape, joined at runtime from a hash so no literal is committed.
  FAKE_PAT="gh""p_$(printf 'h0-1 fixture' | sha256sum | cut -c1-36)"
  T=$(repo added-then-removed)
  (
    cd "$T" || exit 1
    echo "GH=$FAKE_PAT" > config.env
    git add config.env && git commit -q -m 'add config'
    git rm -q config.env && git commit -q -m 'remove config'
  )
  LEAK_SHA=$(git -C "$T" rev-parse HEAD~1)
  assert_eq "" "$(git -C "$T" ls-files config.env)" "the head tree no longer holds the token file"
  run_scan "$T" "$ARCHIVE" base HEAD
  assert_eq "1" "$RC" "a token added and then removed in the range exits 1"
  assert_contains "$OUT" "$LEAK_SHA" "the commit that added the token is named"
  assert_contains "$OUT" "config.env" "the file is named"
  assert_contains "$OUT" "github-pat" "the rule is named"
  assert_not_contains "$OUT" "$FAKE_PAT" "the token is not printed"
  assert_not_contains "$OUT" "${FAKE_PAT#ghp_}" "no part of the token body is printed"
fi

if [ -n "$SKIP_REASON" ]; then
  printf '  --- %d checks, %d failed; scan checks skipped: %s\n' "$TESTS_RUN" "$TESTS_FAILED" "$SKIP_REASON"
  [ "$TESTS_FAILED" -eq 0 ] || exit 1
  exit 0
fi
finish
