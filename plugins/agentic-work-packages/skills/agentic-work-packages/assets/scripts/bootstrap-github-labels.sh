#!/usr/bin/env bash
# Create the work-package label set in a GitHub repo.
# Usage: ./bootstrap-github-labels.sh <owner>/<repo> [program-label] [worker-id...]
# Each worker-id creates worker:<id>, the ownership label for multi-account runs.
set -euo pipefail

REPO="${1:?usage: $0 <owner>/<repo> [program-label] [worker-id...]}"
PROGRAM="${2:-}"
WORKERS=("${@:3}")

# Validate every id before creating anything, so a bad id cannot leave a partial set.
for w in ${WORKERS[@]+"${WORKERS[@]}"}; do
  case "$w" in
    ''|*[!A-Za-z0-9_-]*) echo "invalid worker id [$w]; use letters, digits, _ and - only." >&2; exit 64 ;;
  esac
done

create() {
  local name="$1" color="$2" desc="$3"
  if gh label create "$name" --repo "$REPO" --color "$color" --description "$desc" 2>/dev/null; then
    echo "created  $name"
  else
    gh label edit "$name" --repo "$REPO" --color "$color" --description "$desc" >/dev/null
    echo "updated  $name"
  fi
}

create "epic"                 "5319e7" "Large feature or collection of related issues"
create "agent-ready"          "0e8a16" "No human judgement needed - safe to dispatch to an agent"
create "cell:queued"          "fbca04" "Dependencies merged, waiting for capacity"
create "cell:active"          "1d76db" "An agent is working it"
create "cell:awaiting-review" "d93f0b" "PR open, needs human review"
create "cell:blocked"         "b60205" "Agent stopped, needs coordinator action"
create "cell:merged"          "0e8a16" "Complete"
create "cell:contract-change" "e99695" "Modifies a frozen contract - never runs in parallel"

if [ -n "$PROGRAM" ]; then
  create "$PROGRAM" "c5def5" "Program label"
fi

for w in ${WORKERS[@]+"${WORKERS[@]}"}; do
  create "worker:$w" "bfd4f2" "Owned by worker account $w; written only by the coordinator"
done

echo
echo "Done. Label the epic 'epic' + '$PROGRAM', and first-wave packages"
echo "'agent-ready' + 'cell:queued'."
