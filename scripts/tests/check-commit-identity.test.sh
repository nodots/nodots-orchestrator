#!/usr/bin/env bash
# Fixture test for scripts/check-commit-identity.sh: over base..head it exits 1
# when a commit carries an AI identity (the fleet author or committer, the
# Anthropic noreply email) or an AI Co-Authored-By trailer, and prints the short
# sha and the reason. A clean commit, and a body that names Claude outside a
# trailer, exit 0. Every case runs on a throwaway repo.
set -uo pipefail
cd "$(dirname "$0")"
. ../../plugins/fleet/tests/lib.sh

SCRIPT="$(cd .. && pwd -P)/check-commit-identity.sh"
assert_file "$SCRIPT" "scripts/check-commit-identity.sh exists"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
TMP=$(cd "$TMP" && pwd -P)

HUMAN_NAME="Pat Human"
HUMAN_EMAIL="pat@example.com"

# repo <name> — a git repo with one human commit tagged "base", HEAD on "work".
repo() {
  local d="$TMP/$1"
  mkdir -p "$d"
  (
    cd "$d" || exit 1
    git init -q -b base .
    git config user.email "$HUMAN_EMAIL"
    git config user.name "$HUMAN_NAME"
    echo base > f.txt
    git add f.txt
    git commit -q -m base
    git tag start
    git checkout -q -b work
  )
  echo "$d"
}

# commit_as <repo> <author name> <author email> <committer name> <committer email> <message>
commit_as() {
  (
    cd "$1" || exit 1
    echo "$RANDOM$RANDOM" >> f.txt
    git add f.txt
    GIT_AUTHOR_NAME="$2" GIT_AUTHOR_EMAIL="$3" \
      GIT_COMMITTER_NAME="$4" GIT_COMMITTER_EMAIL="$5" \
      git commit -q -m "$6"
  )
}

# human <repo> <message> — a commit by the human for author and committer.
human() { commit_as "$1" "$HUMAN_NAME" "$HUMAN_EMAIL" "$HUMAN_NAME" "$HUMAN_EMAIL" "$2"; }

run_in() { OUT=$(cd "$1" && bash "$SCRIPT" start HEAD 2>&1); RC=$?; }
short_head() { git -C "$1" rev-parse --short HEAD; }

# --- passing cases ---

T=$(repo clean)
human "$T" "fix: a clean commit"
run_in "$T"
assert_eq "0" "$RC" "a clean human commit exits 0"

T=$(repo mention)
human "$T" "docs: explain the reviewer

Claude reviewed an earlier draft and OpenAI's GPT was compared.
This body names Claude outside any trailer."
run_in "$T"
assert_eq "0" "$RC" "a body that mentions Claude outside a trailer exits 0"

T=$(repo human-trailer)
human "$T" "feat: pair work

Co-Authored-By: Sam Person <sam@example.com>"
run_in "$T"
assert_eq "0" "$RC" "a human Co-Authored-By trailer exits 0"

T=$(repo empty-range)
run_in "$T"
assert_eq "0" "$RC" "an empty range exits 0"

# --- identity cases ---

T=$(repo fleet-author)
commit_as "$T" fleet "$HUMAN_EMAIL" "$HUMAN_NAME" "$HUMAN_EMAIL" "chore: by fleet"
run_in "$T"
assert_eq "1" "$RC" "a fleet author exits 1"
assert_contains "$OUT" "$(short_head "$T")" "the fleet-author commit's short sha is printed"
assert_contains "$OUT" "author name" "the reason names the author"

T=$(repo fleet-committer)
commit_as "$T" "$HUMAN_NAME" "$HUMAN_EMAIL" fleet "$HUMAN_EMAIL" "chore: committed by fleet"
run_in "$T"
assert_eq "1" "$RC" "a fleet committer exits 1"
assert_contains "$OUT" "$(short_head "$T")" "the fleet-committer commit's short sha is printed"
assert_contains "$OUT" "committer name" "the reason names the committer"

T=$(repo fleet-email)
commit_as "$T" "$HUMAN_NAME" fleet@nodots.invalid "$HUMAN_NAME" "$HUMAN_EMAIL" "chore: fleet email"
run_in "$T"
assert_eq "1" "$RC" "the fleet email as author exits 1"
assert_contains "$OUT" "fleet@nodots.invalid" "the reason names the fleet email"

T=$(repo fleet-committer-email)
commit_as "$T" "$HUMAN_NAME" "$HUMAN_EMAIL" "$HUMAN_NAME" fleet@nodots.invalid "chore: fleet committer email"
run_in "$T"
assert_eq "1" "$RC" "the fleet email as committer exits 1"

T=$(repo anthropic-author)
commit_as "$T" "Claude" noreply@anthropic.com "$HUMAN_NAME" "$HUMAN_EMAIL" "chore: AI author"
run_in "$T"
assert_eq "1" "$RC" "the Anthropic noreply email as author exits 1"
assert_contains "$OUT" "noreply@anthropic.com" "the reason names the Anthropic email"

T=$(repo anthropic-committer)
commit_as "$T" "$HUMAN_NAME" "$HUMAN_EMAIL" "Some Name" NoReply@Anthropic.com "chore: AI committer"
run_in "$T"
assert_eq "1" "$RC" "the Anthropic noreply email as committer exits 1, case-insensitive"

# --- trailer cases: one repo per pattern ---

for pat in \
  "Claude Opus 5.5 <someone@example.com>" \
  "Anthropic Bot <bot@example.com>" \
  "Someone <noreply@anthropic.com>" \
  "ChatGPT <bot@example.com>" \
  "OpenAI <bot@example.com>" \
  "Codex <bot@example.com>" \
  "GitHub Copilot <bot@example.com>" \
  "Gemini <bot@example.com>" \
  "Cursor Agent <bot@example.com>"; do
  T=$(repo "trailer-$RANDOM$RANDOM")
  human "$T" "feat: assisted

Co-Authored-By: $pat"
  run_in "$T"
  assert_eq "1" "$RC" "a Co-Authored-By trailer naming [$pat] exits 1"
  assert_contains "$OUT" "$(short_head "$T")" "the trailer commit's short sha is printed for [$pat]"
done

T=$(repo trailer-case)
human "$T" "feat: assisted

co-authored-by: CLAUDE <x@example.com>"
run_in "$T"
assert_eq "1" "$RC" "trailer key and value match case-insensitively"
assert_contains "$OUT" "trailer" "the reason names the trailer"

# --- mixed range: only the bad commit is named, every bad commit is named ---

T=$(repo mixed)
human "$T" "fix: first, clean"
GOOD=$(short_head "$T")
commit_as "$T" fleet fleet@nodots.invalid fleet fleet@nodots.invalid "chore: second, fleet"
BAD1=$(short_head "$T")
human "$T" "feat: third

Co-Authored-By: Claude <noreply@anthropic.com>"
BAD2=$(short_head "$T")
run_in "$T"
assert_eq "1" "$RC" "a range holding a bad commit exits 1"
assert_contains "$OUT" "$BAD1" "the first bad commit is named"
assert_contains "$OUT" "$BAD2" "the second bad commit is named"
assert_not_contains "$OUT" "$GOOD" "the clean commit is not named"

# --- usage errors are not a pass ---

T=$(repo usage)
OUT=$(cd "$T" && bash "$SCRIPT" 2>&1); RC=$?
assert_ne "0" "$RC" "no arguments exits non-zero"
OUT=$(cd "$T" && bash "$SCRIPT" no-such-ref HEAD 2>&1); RC=$?
assert_ne "0" "$RC" "an unknown base ref exits non-zero"
assert_ne "1" "$RC" "an unknown base ref is not reported as an identity failure"

finish
