#!/usr/bin/env bash
# Refuse AI commit identity: bash scripts/check-commit-identity.sh <base> <head>
# CI runs it on every pull request over the commits the PR adds.
#
# For each commit in base..head it fails the commit when:
#   - the author or committer name is "fleet", or the email is fleet@nodots.invalid;
#   - the author or committer email is noreply@anthropic.com;
#   - any trailer, under any key (Co-Authored-By:, Agent-Assisted: or another),
#     names Claude, Anthropic, noreply@anthropic.com, GPT, OpenAI, Codex,
#     Copilot, Gemini or Cursor.
# The trailer that records agent work, Agent-Assisted: yes, names none of them
# and passes. Names, emails and trailers match case-insensitively. A trailer is
# what git reads as the message's trailer block (%(trailers)); a Co-Authored-By:
# line elsewhere in the message also counts. A name mentioned in the body
# outside a trailer does not.
#
# Prints each failing commit's short sha and the reason. Exits 1 when any commit
# fails, 0 when none does, 2 on a usage error or a range git cannot resolve.
#
# What it does not catch:
#   - an AI identity under a human-looking name and email;
#   - trailer spellings outside the list above, and attribution in other forms
#     (a "Generated with" line in the body, an AI tool not listed).
set -uo pipefail

if [ $# -ne 2 ]; then
  echo "usage: $0 <base> <head>" >&2
  exit 2
fi
base=$1
head=$2

if ! commits=$(git rev-list --reverse "$base..$head" 2>&1); then
  echo "error: cannot list commits in $base..$head: $commits" >&2
  exit 2
fi

AI_RE='claude|anthropic|gpt|openai|codex|copilot|gemini|cursor'
lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

failed=0
checked=0
for c in $commits; do
  checked=$((checked + 1))
  short=$(git rev-parse --short "$c")
  IFS=$'\t' read -r an ae cn ce < <(git show -s --format='%an%x09%ae%x09%cn%x09%ce' "$c")
  reasons=()
  for role in author committer; do
    if [ "$role" = author ]; then name=$an; email=$ae; else name=$cn; email=$ce; fi
    [ "$(lower "$name")" = fleet ] && reasons+=("$role name is fleet")
    case "$(lower "$email")" in
      fleet@nodots.invalid) reasons+=("$role email is fleet@nodots.invalid") ;;
      noreply@anthropic.com) reasons+=("$role email is noreply@anthropic.com") ;;
    esac
  done
  while IFS= read -r line; do
    reasons+=("trailer names an AI model or vendor: $line")
  done < <({ git show -s --format='%(trailers:only,unfold)' "$c"
             git show -s --format=%B "$c" | grep -iE '^[[:space:]]*co-authored-by:'
           } | sed 's/^[[:space:]]*//' | awk '!seen[tolower($0)]++' | grep -iE "$AI_RE")
  if [ ${#reasons[@]} -gt 0 ]; then
    failed=$((failed + 1))
    for r in "${reasons[@]}"; do echo "FAIL  $short  $r"; done
  fi
done

if [ $failed -gt 0 ]; then
  echo "$failed of $checked commit(s) in $base..$head carry an AI identity or trailer."
  exit 1
fi
echo "OK  $checked commit(s) in $base..$head carry no AI identity or trailer."
exit 0
