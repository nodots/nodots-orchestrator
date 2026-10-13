#!/usr/bin/env bash
# The one test command. CI runs it, and so should you: bash scripts/test.sh
# Exits 0 when every check holds, non-zero on any failure.
#
# 1. The plugin hooks and their manual-install copies are byte-identical.
# 2. Every .js and .sh under plugins/ parses (scripts/check-syntax.sh).
# 3. No changed file holds a private-key header or token (scripts/check-credentials.sh).
# 4. Every fixture test (*.test.sh) passes. A glob that matches nothing fails.
#
# REPO_ROOT overrides the tree under test; scripts/tests/test-sh.test.sh uses it.
set -uo pipefail
shopt -s nullglob

SELF_DIR="$(cd "$(dirname "$0")" && pwd -P)"
REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "$0")/.." && pwd -P)}"
cd "$REPO_ROOT" || exit 1

AWP=plugins/agentic-work-packages
ASSETS=$AWP/skills/agentic-work-packages/assets
status=0

echo "=== hook copies are byte-identical ==="
hooks=("$AWP"/hooks/*.js)
if [ ${#hooks[@]} -eq 0 ]; then
  echo "FAIL  No plugin hooks found - the glob matched nothing."
  status=1
fi
for h in "${hooks[@]}"; do
  name=$(basename "$h")
  if [ ! -f "$ASSETS/hooks/$name" ]; then
    echo "FAIL  Missing manual-install copy: $ASSETS/hooks/$name"
    status=1
  elif diff "$h" "$ASSETS/hooks/$name"; then
    echo "PASS  $name"
  else
    echo "FAIL  $name differs from $ASSETS/hooks/$name"
    status=1
  fi
done

echo "=== syntax (parse check, not a style lint) ==="
if ! REPO_ROOT="$REPO_ROOT" bash "$SELF_DIR/check-syntax.sh"; then status=1; fi

echo "=== credentials in changed files ==="
if ! REPO_ROOT="$REPO_ROOT" bash "$SELF_DIR/check-credentials.sh"; then status=1; fi

echo "=== fixture tests ==="
tests=("$ASSETS"/tests/*.test.sh plugins/fleet/tests/*.test.sh scripts/tests/*.test.sh)
if [ ${#tests[@]} -eq 0 ]; then
  echo "FAIL  No fixture tests found - the glob matched nothing."
  exit 1
fi
for t in "${tests[@]}"; do
  out=$(bash "$t" 2>&1)
  rc=$?
  summary=$(printf '%s\n' "$out" | grep -E -- '--- [0-9]+ checks' | tail -n 1 | sed 's/^ *//')
  if [ $rc -eq 0 ]; then
    echo "PASS  $t  ${summary:-(no tally printed)}"
  else
    echo "FAIL  $t  ${summary:-(no tally printed)}"
    printf '%s\n' "$out" | sed 's/^/      /'
    status=1
  fi
done

if [ $status -eq 0 ]; then echo "ALL PASS"; else echo "FAILED"; fi
exit $status
