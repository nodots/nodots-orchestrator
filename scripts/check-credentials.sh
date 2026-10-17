#!/usr/bin/env bash
# Credential check: scan the files changed against a base ref for private-key
# headers and common token prefixes. Committed changes since the merge base,
# staged and unstaged edits, and untracked files all count.
#
# This is a pattern match, not a secret scanner: it finds the shapes listed in
# PATTERNS below and nothing else. Output names the file, never the match.
#
# BASE_REF   base to diff against (default: origin/development). An unresolvable
#            ref fails the check rather than skipping it.
# REPO_ROOT  overrides the tree under test. A tree that is not a git work tree
#            has no base to diff against, so every file in it is scanned.
set -uo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "$0")/.." && pwd -P)}"
BASE_REF="${BASE_REF:-origin/development}"
cd "$REPO_ROOT" || exit 1

# Each pattern's source text does not match itself, so this file passes its own scan.
PATTERNS=(
  '-----BEGIN ([A-Z]+ )*PRIVATE KEY-----'
  'AKIA[0-9A-Z]{16}'
  'ASIA[0-9A-Z]{16}'
  'gh[pousr]_[A-Za-z0-9]{36}'
  'github_pat_[A-Za-z0-9_]{22,}'
  'xox[baprs]-[A-Za-z0-9-]{10,}'
  'sk-ant-[A-Za-z0-9_-]{20,}'
  'AIza[0-9A-Za-z_-]{35}'
)

files=()
if git rev-parse --is-inside-work-tree >/dev/null 2>&1 && [ "$(git rev-parse --show-toplevel)" = "$REPO_ROOT" ]; then
  if ! base=$(git merge-base "$BASE_REF" HEAD 2>/dev/null); then
    echo "FAIL  Cannot resolve a merge base with '$BASE_REF'. Fetch it or set BASE_REF."
    exit 1
  fi
  while IFS= read -r f; do files+=("$f"); done < <(
    { git diff --name-only --diff-filter=ACMR "$base"; git ls-files --others --exclude-standard; } | sort -u
  )
  echo "scanning ${#files[@]} file(s) changed against $BASE_REF"
else
  while IFS= read -r f; do files+=("$f"); done < <(find . -type f -not -path './.git/*' | sed 's|^\./||' | sort)
  echo "not a git work tree: scanning all ${#files[@]} file(s)"
fi

regex=$(IFS='|'; echo "${PATTERNS[*]}")
status=0
for f in ${files[@]+"${files[@]}"}; do
  [ -f "$f" ] || continue
  if grep -I -E -q -e "$regex" -- "$f"; then
    echo "FAIL  $f holds a private-key header or token-shaped string"
    status=1
  fi
done

[ $status -eq 0 ] && echo "PASS  no credential patterns in changed files"
exit $status
