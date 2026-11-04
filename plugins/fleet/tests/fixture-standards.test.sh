#!/usr/bin/env bash
# fixture_standards (lib.sh): a fixture clone given the helper publishes a
# .claude/standards.json that check-standards.js accepts, committed and silent.
# Every fleet suite that launches into a fixture target calls it in its setup,
# so a launch that requires a valid manifest still runs the real launch path.
set -uo pipefail
cd "$(dirname "$0")"
. ./lib.sh

CHECK="$(cd ../../agentic-work-packages && pwd -P)/skills/agentic-work-packages/assets/scripts/check-standards.js"
assert_file "$CHECK" "check-standards.js exists"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
TMP=$(cd "$TMP" && pwd -P)

# --- the helper on a README-only repo -----------------------------------------
git init -q -b main "$TMP/repo"
git -C "$TMP/repo" config user.email f@example.invalid; git -C "$TMP/repo" config user.name fixture
printf '# api\n' > "$TMP/repo/README.md"
git -C "$TMP/repo" add -A && git -C "$TMP/repo" commit -qm init

defined=$(type -t fixture_standards || true)
assert_eq "function" "$defined" "lib.sh defines fixture_standards"

if [ "$defined" = "function" ]; then
  out=$(fixture_standards "$TMP/repo" 2>&1); rc=$?
  assert_eq "0" "$rc" "fixture_standards exits 0"
  assert_empty "$out" "fixture_standards prints nothing on success"
fi

node "$CHECK" --root "$TMP/repo" >"$TMP/check.out" 2>"$TMP/check.err"; rc=$?
assert_eq "0" "$rc" "check-standards.js exits 0 on the fixture manifest"
assert_empty "$(cat "$TMP/check.err")" "check-standards.js reports nothing"

assert_empty "$(git -C "$TMP/repo" status --porcelain)" "the manifest is committed, the tree is clean"
assert_eq ".claude/standards.json" "$(git -C "$TMP/repo" diff --name-only HEAD~1 HEAD 2>/dev/null)" "the helper's commit adds only the manifest"
assert_eq "fixture: standards manifest" "$(git -C "$TMP/repo" log -1 --format=%s 2>/dev/null)" "the commit message"

# --- a git failure is a non-zero exit -----------------------------------------
if [ "$defined" = "function" ]; then
  mkdir -p "$TMP/not-a-repo"
  fixture_standards "$TMP/not-a-repo" >/dev/null 2>&1; rc=$?
  assert_ne "0" "$rc" "fixture_standards fails outside a git repo"
fi

# --- every suite that launches into a fixture target calls it -----------------
for suite in adoption ci-preconditions cycle daemon epic-scope v4-gate vanished verify-config verify-manual verify-stage; do
  if grep -qE '^[[:space:]]*fixture_standards ' "$suite.test.sh"; then
    _pass "$suite.test.sh calls fixture_standards"
  else
    _fail "$suite.test.sh calls fixture_standards" "no fixture_standards call in $suite.test.sh"
  fi
done

finish
