#!/usr/bin/env bash
# The one test command. CI runs it, and so should you: bash scripts/test.sh
# Exits 0 when every check holds, non-zero on any failure.
#
# 1. The plugin hooks and their manual-install copies are byte-identical.
# 2. The installed worker hooks (.claude/hooks/) and contract (.claude/worker-contract.md)
#    are byte-identical to the plugin's. enforce-scope.js and require-handoff.js must be
#    installed; any other plugin hook that is installed must match too.
# 3. Every .js and .sh under plugins/ parses (scripts/check-syntax.sh).
# 4. No changed file holds a private-key header or token (scripts/check-credentials.sh).
# 5. Every fixture test (*.test.sh) passes. A glob that matches nothing fails.
# 6. Every eval test (evals/tests/*.test.js, evals/gates/*.test.js) passes under node.
#    A glob that matches nothing fails. These tests stub the model; none may call one.
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

echo "=== installed worker hooks and contract match the plugin copies ==="
# The worker hooks must be installed. Any other plugin hook that is installed must match too.
required_hooks=" enforce-scope.js require-handoff.js "
for h in "${hooks[@]}"; do
  name=$(basename "$h")
  if [ ! -f ".claude/hooks/$name" ]; then
    case "$required_hooks" in
      *" $name "*) echo "FAIL  Missing installed hook: .claude/hooks/$name"; status=1 ;;
    esac
  elif diff ".claude/hooks/$name" "$h"; then
    echo "PASS  .claude/hooks/$name"
  else
    echo "FAIL  .claude/hooks/$name differs from $h"
    status=1
  fi
done
for name in $required_hooks; do
  if [ ! -f "$AWP/hooks/$name" ]; then
    echo "FAIL  Missing plugin hook: $AWP/hooks/$name"
    status=1
  fi
done
if [ ! -f .claude/worker-contract.md ]; then
  echo "FAIL  Missing installed contract: .claude/worker-contract.md"
  status=1
elif diff .claude/worker-contract.md "$ASSETS/worker-contract.md"; then
  echo "PASS  .claude/worker-contract.md"
else
  echo "FAIL  .claude/worker-contract.md differs from $ASSETS/worker-contract.md"
  status=1
fi

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

echo "=== eval tests (node, no model calls) ==="
for dir in evals/tests evals/gates; do
  evals=("$dir"/*.test.js)
  if [ ${#evals[@]} -eq 0 ]; then
    echo "FAIL  No eval tests found in $dir - the glob matched nothing."
    status=1
    continue
  fi
  for t in "${evals[@]}"; do
    out=$(node "$t" 2>&1)
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
done

if [ $status -eq 0 ]; then echo "ALL PASS"; else echo "FAILED"; fi
exit $status
