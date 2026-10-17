#!/usr/bin/env bash
# Fixture test for scripts/check-syntax.sh: exits 0 on valid .js and .sh files
# under plugins/, non-zero on a syntax error in either, or when nothing matches.
set -uo pipefail
cd "$(dirname "$0")"
. ../../plugins/fleet/tests/lib.sh

SCRIPT="$(cd .. && pwd -P)/check-syntax.sh"
assert_file "$SCRIPT" "scripts/check-syntax.sh exists"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
TMP=$(cd "$TMP" && pwd -P)

# fixture <name> — a healthy tree: one valid .js and one valid .sh under plugins/.
fixture() {
  local d="$TMP/$1"
  mkdir -p "$d/plugins/p"
  echo 'module.exports = 1;' > "$d/plugins/p/a.js"
  printf '#!/usr/bin/env bash\necho ok\n' > "$d/plugins/p/a.sh"
  echo "$d"
}

run_in() { OUT=$(REPO_ROOT="$1" bash "$SCRIPT" 2>&1); RC=$?; }

T=$(fixture healthy)
run_in "$T"
assert_eq "0" "$RC" "healthy tree exits 0"

T=$(fixture bad-js)
echo 'function ( {' > "$T/plugins/p/bad.js"
run_in "$T"
assert_ne "0" "$RC" "a .js syntax error exits non-zero"
assert_contains "$OUT" "plugins/p/bad.js" "the broken .js file is named"

T=$(fixture bad-sh)
printf 'if then fi (\n' > "$T/plugins/p/bad.sh"
run_in "$T"
assert_ne "0" "$RC" "a .sh syntax error exits non-zero"
assert_contains "$OUT" "plugins/p/bad.sh" "the broken .sh file is named"

T=$(fixture empty)
rm "$T/plugins/p/a.js" "$T/plugins/p/a.sh"
run_in "$T"
assert_ne "0" "$RC" "no files to check exits non-zero"
assert_contains "$OUT" "matched nothing" "empty glob is reported"

finish
