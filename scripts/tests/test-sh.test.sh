#!/usr/bin/env bash
# Fixture test for scripts/test.sh: exits 0 on a healthy tree, non-zero on a
# failing test, an empty glob, a hook copy that differs, or an installed hook
# or contract under .claude/ that differs from the plugin's or is missing.
set -uo pipefail
cd "$(dirname "$0")"
. ../../plugins/fleet/tests/lib.sh

SCRIPT="$(cd .. && pwd -P)/test.sh"
assert_file "$SCRIPT" "scripts/test.sh exists"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
TMP=$(cd "$TMP" && pwd -P)

AWP=plugins/agentic-work-packages
HOOKS=$AWP/hooks
ASSETS=$AWP/skills/agentic-work-packages/assets

# fixture <name> — a healthy tree: hooks with matching copies, the worker hooks
# and contract installed under .claude/, one passing test.
fixture() {
  local d="$TMP/$1" h
  mkdir -p "$d/$HOOKS" "$d/$ASSETS/hooks" "$d/$ASSETS/tests" "$d/plugins/fleet/tests" "$d/scripts/tests" "$d/evals/tests" "$d/evals/gates" "$d/.claude/hooks"
  echo 'module.exports = 1;' > "$d/$HOOKS/a.js"
  echo 'module.exports = "scope";' > "$d/$HOOKS/enforce-scope.js"
  echo 'module.exports = "handoff";' > "$d/$HOOKS/require-handoff.js"
  for h in a.js enforce-scope.js require-handoff.js; do cp "$d/$HOOKS/$h" "$d/$ASSETS/hooks/$h"; done
  for h in enforce-scope.js require-handoff.js; do cp "$d/$HOOKS/$h" "$d/.claude/hooks/$h"; done
  echo '# Worker contract' > "$d/$ASSETS/worker-contract.md"
  cp "$d/$ASSETS/worker-contract.md" "$d/.claude/worker-contract.md"
  printf '#!/usr/bin/env bash\necho "  --- 3 checks, 0 failed"\nexit 0\n' > "$d/plugins/fleet/tests/ok.test.sh"
  printf 'console.log("  --- 4 checks, 0 failed");\n' > "$d/evals/tests/ok.test.js"
  printf 'console.log("  --- 5 checks, 0 failed");\n' > "$d/evals/gates/ok.test.js"
  echo "$d"
}

# run_in <tree> — run scripts/test.sh against a fixture tree.
run_in() { OUT=$(REPO_ROOT="$1" bash "$SCRIPT" 2>&1); RC=$?; }

T=$(fixture healthy)
run_in "$T"
assert_eq "0" "$RC" "healthy tree exits 0"
assert_contains "$OUT" "3 checks" "healthy tree prints the pass count per file"
assert_contains "$OUT" "plugins/fleet/tests/ok.test.sh" "healthy tree names the file"

T=$(fixture failing)
printf '#!/usr/bin/env bash\necho "  --- 2 checks, 1 failed"\nexit 1\n' > "$T/scripts/tests/bad.test.sh"
run_in "$T"
assert_ne "0" "$RC" "a failing .test.sh exits non-zero"
assert_contains "$OUT" "FAIL" "a failing .test.sh is reported"

T=$(fixture no-tests)
rm "$T/plugins/fleet/tests/ok.test.sh"
run_in "$T"
assert_ne "0" "$RC" "no matching test files exits non-zero"
assert_contains "$OUT" "matched nothing" "empty glob is reported"

T=$(fixture evals-pass)
run_in "$T"
assert_eq "0" "$RC" "passing eval tests exit 0"
assert_contains "$OUT" "PASS  evals/tests/ok.test.js  --- 4 checks" "a passing evals/tests file gets PASS and its tally"
assert_contains "$OUT" "PASS  evals/gates/ok.test.js  --- 5 checks" "a passing evals/gates file gets PASS and its tally"

T=$(fixture evals-tests-failing)
printf 'console.log("  --- 2 checks, 1 failed");\nprocess.exitCode = 1;\n' > "$T/evals/tests/bad.test.js"
run_in "$T"
assert_ne "0" "$RC" "a failing evals/tests file exits non-zero"
assert_contains "$OUT" "FAIL  evals/tests/bad.test.js" "a failing evals/tests file is reported as FAIL"

T=$(fixture evals-gates-failing)
printf 'throw new Error("boom");\n' > "$T/evals/gates/bad.test.js"
run_in "$T"
assert_ne "0" "$RC" "a throwing evals/gates file exits non-zero"
assert_contains "$OUT" "FAIL  evals/gates/bad.test.js" "a throwing evals/gates file is reported as FAIL"

T=$(fixture evals-tests-empty)
rm "$T/evals/tests/ok.test.js"
run_in "$T"
assert_ne "0" "$RC" "an empty evals/tests glob exits non-zero"
assert_contains "$OUT" "No eval tests found in evals/tests" "an empty evals/tests glob is reported"

T=$(fixture evals-gates-empty)
rm "$T/evals/gates/ok.test.js"
run_in "$T"
assert_ne "0" "$RC" "an empty evals/gates glob exits non-zero"
assert_contains "$OUT" "No eval tests found in evals/gates" "an empty evals/gates glob is reported"

T=$(fixture hook-differs)
echo 'module.exports = 2;' > "$T/$ASSETS/hooks/a.js"
run_in "$T"
assert_ne "0" "$RC" "a differing hook copy exits non-zero"

T=$(fixture hook-missing)
rm "$T/$ASSETS/hooks/a.js"
run_in "$T"
assert_ne "0" "$RC" "a missing hook copy exits non-zero"

T=$(fixture no-hooks)
rm "$T/$HOOKS"/*.js
run_in "$T"
assert_ne "0" "$RC" "no hooks exits non-zero"
assert_contains "$OUT" "No plugin hooks found" "no hooks is reported as an empty glob"

T=$(fixture installed-healthy)
run_in "$T"
assert_eq "0" "$RC" "installed hooks and contract that match exit 0"
assert_contains "$OUT" "PASS  .claude/hooks/enforce-scope.js" "a matching installed hook gets a PASS line"
assert_contains "$OUT" "PASS  .claude/hooks/require-handoff.js" "each installed hook gets its own PASS line"
assert_contains "$OUT" "PASS  .claude/worker-contract.md" "a matching installed contract gets a PASS line"

T=$(fixture installed-hook-differs)
echo 'module.exports = "edited";' > "$T/.claude/hooks/enforce-scope.js"
run_in "$T"
assert_ne "0" "$RC" "an installed hook that differs exits non-zero"
assert_contains "$OUT" "FAIL  .claude/hooks/enforce-scope.js differs" "an installed hook that differs is named"

T=$(fixture installed-hook-missing)
rm "$T/.claude/hooks/require-handoff.js"
run_in "$T"
assert_ne "0" "$RC" "a missing installed hook exits non-zero"
assert_contains "$OUT" "FAIL  Missing installed hook: .claude/hooks/require-handoff.js" "a missing installed hook is named"

T=$(fixture installed-other-hook-differs)
echo 'module.exports = 3;' > "$T/.claude/hooks/a.js"
run_in "$T"
assert_ne "0" "$RC" "any other installed plugin hook that differs exits non-zero"
assert_contains "$OUT" "FAIL  .claude/hooks/a.js differs" "the other differing installed hook is named"

T=$(fixture contract-differs)
echo '# Edited contract' > "$T/.claude/worker-contract.md"
run_in "$T"
assert_ne "0" "$RC" "an installed contract that differs exits non-zero"
assert_contains "$OUT" "FAIL  .claude/worker-contract.md differs" "a differing contract is named"

T=$(fixture contract-missing)
rm "$T/.claude/worker-contract.md"
run_in "$T"
assert_ne "0" "$RC" "a missing installed contract exits non-zero"
assert_contains "$OUT" "FAIL  Missing installed contract: .claude/worker-contract.md" "a missing contract is named"

finish
