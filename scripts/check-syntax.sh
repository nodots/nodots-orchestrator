#!/usr/bin/env bash
# Syntax check: `node --check` on every .js under plugins/, `bash -n` on every .sh.
#
# This is a parse check only. It is NOT a style linter: it does not flag unused
# variables, quoting mistakes, shellcheck findings, or formatting. A file that
# parses passes.
#
# Exits 0 when every file parses, non-zero on any parse error or when no file matches.
# REPO_ROOT overrides the tree under test.
set -uo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "$0")/.." && pwd -P)}"
cd "$REPO_ROOT" || exit 1

status=0
js=()
sh=()
while IFS= read -r f; do js+=("$f"); done < <(find plugins -type f -name '*.js' -not -path '*/node_modules/*' 2>/dev/null | sort)
while IFS= read -r f; do sh+=("$f"); done < <(find plugins -type f -name '*.sh' -not -path '*/node_modules/*' 2>/dev/null | sort)

if [ ${#js[@]} -eq 0 ] && [ ${#sh[@]} -eq 0 ]; then
  echo "FAIL  No .js or .sh files found under plugins/ - the glob matched nothing."
  exit 1
fi

for f in ${js[@]+"${js[@]}"}; do
  if err=$(node --check "$f" 2>&1); then
    echo "PASS  $f"
  else
    echo "FAIL  $f (node --check)"
    printf '%s\n' "$err" | sed 's/^/      /'
    status=1
  fi
done

for f in ${sh[@]+"${sh[@]}"}; do
  if err=$(bash -n "$f" 2>&1); then
    echo "PASS  $f"
  else
    echo "FAIL  $f (bash -n)"
    printf '%s\n' "$err" | sed 's/^/      /'
    status=1
  fi
done

echo "checked ${#js[@]} .js and ${#sh[@]} .sh files (syntax only, not a style lint)"
exit $status
