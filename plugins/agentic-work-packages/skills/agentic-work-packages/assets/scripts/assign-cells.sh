#!/usr/bin/env bash
# assign-cells.sh — the coordinator account's dispatch step: assign queued
# packages to worker accounts by labeling them worker:<id>.
#
# The tracker is the message bus. This script is the only writer of worker:*
# labels; each worker account reads only the packages carrying its own label.
# Nothing here launches, signals or inspects a worker session.
#
# A package is a candidate when it is open, agent-ready, cell:queued and has no
# worker:* label. Candidates are taken in issue-number order and each goes to
# the worker with the lowest load (ties broken by the order of --workers).
#
# Load is what is in flight: a package that is cell:active, or cell:queued with
# a worker:* label already on it. Assigned-but-unstarted packages count, or two
# cycles in a row would hand the same free slot out twice.
#
# Holds, first match wins, per candidate:
#   - the fleet is at --wip-cap                  -> hold
#   - a cell:contract-change package is in flight -> hold everything
#   - a contract-change candidate and the fleet is not empty
#                                                -> hold it and everything after
#                                                   it, so the fleet drains
#                                                   rather than starving it
#   - a contract-change candidate and the fleet is empty
#                                                -> assign it, hold everything
#                                                   after it
# See references/multi-account.md.
#
# Usage:
#   assign-cells.sh --repo <owner/repo> --workers a,b [--wip-cap N] [--apply]
#   assign-cells.sh --state <file.json> --workers a,b [--wip-cap N] [--apply]
#
#   --repo      the host repo holding the issue graph
#   --workers   comma-separated worker ids, letters digits _ and - only. Each id
#               is the suffix of its label: worker:<id>. Order is the tiebreak.
#   --wip-cap   cap on packages in flight across all workers (default 4)
#   --state     read collected state from a file instead of calling gh; the gh
#               collector writes exactly this shape, so the derivation runs
#               over a fixture and over a live repo through one code path
#   --apply     write the labels. Without it, nothing is written.
#
# Dependencies: bash, node (builtins only), and gh — gh only when --state is
# absent.
set -uo pipefail

APPLY=0
STATE=""
REPO=""
WORKERS=""
CAP=4

while [ $# -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1; shift ;;
    --state) STATE="${2:-}"; shift 2 ;;
    --repo) REPO="${2:-}"; shift 2 ;;
    --workers) WORKERS="${2:-}"; shift 2 ;;
    --wip-cap) CAP="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,42p' "$0"; exit 0 ;;
    *) printf 'assign-cells: unknown argument: %s\n' "$1" >&2; exit 64 ;;
  esac
done

if [ -z "$STATE" ] && [ -z "$REPO" ]; then
  printf 'assign-cells: one of --state or --repo is required.\n' >&2
  exit 64
fi
if [ -z "$WORKERS" ]; then
  printf 'assign-cells: --workers is required (for example --workers a,b).\n' >&2
  exit 64
fi
case "$CAP" in
  ''|*[!0-9]*|0) printf 'assign-cells: --wip-cap must be a positive integer, got [%s].\n' "$CAP" >&2; exit 64 ;;
esac
# The ids become label names and are passed to gh, so refuse anything else.
IFS=',' read -r -a WORKER_LIST <<< "$WORKERS"
for w in "${WORKER_LIST[@]}"; do
  case "$w" in
    ''|*[!A-Za-z0-9_-]*) printf 'assign-cells: invalid worker id [%s]; use letters, digits, _ and - only.\n' "$w" >&2; exit 64 ;;
  esac
done

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Empty fields in the rows below are written as "-": read with a tab IFS would
# otherwise collapse adjacent tabs and shift every later field left.
# --- the derivation: one code path for fixtures and for live state ----------
cat > "$TMP/derive.js" <<'JS'
'use strict';
const fs = require('fs');

const [statePath, workersArg, capArg] = process.argv.slice(2);
const workers = workersArg.split(',');
const cap = Number(capArg);
const state = JSON.parse(fs.readFileSync(statePath, 'utf8'));

const open = (state.issues || []).filter(i => String(i.state || 'OPEN').toUpperCase() === 'OPEN');
const labelsOf = i => (i.labels || []).map(l => (typeof l === 'string' ? l : l.name));
const workerLabels = i => labelsOf(i).filter(n => n.startsWith('worker:'));
const has = (i, n) => labelsOf(i).includes(n);

const rows = [];   // [number, action, worker, why]
const load = Object.fromEntries(workers.map(w => [w, 0]));
let inFlight = 0;
let contractInFlight = null;

// Packages with more than one worker label have two owners. Flag them and keep
// them out of both the load and the candidates: guessing an owner is how two
// accounts end up on one branch.
const conflicted = new Set();
for (const i of open) {
  if (workerLabels(i).length > 1) {
    conflicted.add(i.number);
    rows.push([i.number, 'warn', '-', `carries ${workerLabels(i).join(' and ')}; one owner only. Resolve by hand.`]);
  }
}

for (const i of open) {
  if (conflicted.has(i.number)) continue;
  const active = has(i, 'cell:active');
  const owned = workerLabels(i)[0];
  const queuedOwned = has(i, 'cell:queued') && owned;
  if (!active && !queuedOwned) continue;
  inFlight += 1;
  if (has(i, 'cell:contract-change') && contractInFlight === null) contractInFlight = i.number;
  if (owned) {
    const id = owned.slice('worker:'.length);
    if (id in load) load[id] += 1;
    else rows.push([i.number, 'warn', '-', `${owned} is not in --workers; counted toward the cap, not toward any listed worker.`]);
  }
}

const candidates = open
  .filter(i => !conflicted.has(i.number) && has(i, 'agent-ready') && has(i, 'cell:queued') && workerLabels(i).length === 0)
  .sort((a, b) => a.number - b.number);

let stop = null;   // a reason that holds every later candidate
for (const i of candidates) {
  if (contractInFlight !== null) { rows.push([i.number, 'hold', '-', `contract-change #${contractInFlight} in flight; nothing runs beside it`]); continue; }
  if (stop) { rows.push([i.number, 'hold', '-', stop]); continue; }
  if (inFlight >= cap) { rows.push([i.number, 'hold', '-', `WIP cap reached (${inFlight}/${cap} in flight)`]); continue; }

  const contract = has(i, 'cell:contract-change');
  if (contract && inFlight > 0) {
    stop = `draining for contract-change #${i.number} (${inFlight} in flight)`;
    rows.push([i.number, 'hold', '-', `contract-change waits for an empty fleet (${inFlight} in flight)`]);
    continue;
  }

  const pick = workers.reduce((best, w) => (load[w] < load[best] ? w : best), workers[0]);
  const snapshot = workers.map(w => `${w}=${load[w]}`).join(' ');
  load[pick] += 1;
  inFlight += 1;
  rows.push([i.number, 'assign', pick, `least loaded: ${snapshot}`]);
  if (contract) stop = `contract-change #${i.number} assigned; nothing runs beside it`;
}

rows.sort((a, b) => a[0] - b[0]);
process.stdout.write(rows.map(r => r.join('\t')).join('\n') + (rows.length ? '\n' : ''));
process.stdout.write(`#load\t${workers.map(w => `${w}=${load[w]}`).join(' ')}\tin flight ${inFlight}/${cap}\n`);
JS

# --- collect live state into the fixture shape ------------------------------
# GH_BIN exists so the collector can be exercised against a stub in the fixture
# test. It defaults to the real gh and is not a user-facing option.
GH="${GH_BIN:-gh}"
PAGE_LIMIT="${ASSIGN_CELLS_PAGE_LIMIT:-1000}"

collect_state() {
  command -v "$GH" >/dev/null 2>&1 || {
    printf 'assign-cells: %s is not on PATH; use --state for an offline run.\n' "$GH" >&2
    exit 69
  }
  "$GH" issue list --repo "$REPO" --state open --limit "$PAGE_LIMIT" \
     --json number,title,labels,state > "$TMP/issues.json" || exit 70

  # A collection that exactly fills the page is indistinguishable from a
  # truncated one. Load computed from half the in-flight packages hands out
  # slots that are not free, so stop rather than assign from partial state.
  local n
  n=$(node -e 'const a=require(process.argv[1]);process.stdout.write(String(a.length))' "$TMP/issues.json") || exit 70
  if [ "$n" -ge "$PAGE_LIMIT" ]; then
    printf 'assign-cells: the issues query returned %s rows, filling the page limit of %s.\n' \
      "$n" "$PAGE_LIMIT" >&2
    printf '  The collection is truncated, so the load computed from it would be wrong.\n' >&2
    printf '  Raise the limit with ASSIGN_CELLS_PAGE_LIMIT and run again.\n' >&2
    exit 75
  fi

  node - "$TMP/issues.json" "$REPO" <<'JS' > "$TMP/state.json" || exit 70
'use strict';
const fs = require('fs');
const issues = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const repo = process.argv[3];
process.stdout.write(JSON.stringify({
  repo,
  issues: issues.map(i => ({ number: i.number, title: i.title, state: i.state, labels: (i.labels || []).map(l => l.name) })),
}, null, 2));
JS
  STATE="$TMP/state.json"
}

[ -n "$STATE" ] || collect_state
[ -f "$STATE" ] || { printf 'assign-cells: no such state file: %s\n' "$STATE" >&2; exit 66; }

node "$TMP/derive.js" "$STATE" "$WORKERS" "$CAP" > "$TMP/rows.tsv" || exit 70

assigned=0
failed=0
while IFS=$'\t' read -r number action worker why; do
  [ -n "${number:-}" ] || continue
  if [ "$number" = "#load" ]; then
    # Not a package row: the closing line, load per worker and the cap.
    printf '\nload: %s; %s\n' "$action" "$worker"
    continue
  fi
  case "$action" in
    assign)
      assigned=$((assigned + 1))
      printf '#%s  assign -> worker:%s   (%s)\n' "$number" "$worker" "$why"
      if [ "$APPLY" = "1" ]; then
        [ -n "$REPO" ] || { printf 'assign-cells: --apply needs --repo.\n' >&2; exit 64; }
        "$GH" issue edit "$number" --repo "$REPO" --add-label "worker:$worker" >/dev/null \
          || { printf '  ! failed to label #%s (does worker:%s exist? see bootstrap-github-labels.sh)\n' "$number" "$worker" >&2; failed=$((failed + 1)); }
      fi
      ;;
    hold) printf '#%s  hold   (%s)\n' "$number" "$why" ;;
    warn) printf '#%s  !      %s\n' "$number" "$why" ;;
    *)    printf 'assign-cells: unrecognized row action [%s] for #%s\n' "$action" "$number" >&2; exit 70 ;;
  esac
done < "$TMP/rows.tsv"

if [ "$APPLY" = "1" ]; then
  printf '\n%d label(s) written, %d failed.\n' "$((assigned - failed))" "$failed"
  [ "$failed" -eq 0 ] || exit 1
else
  printf '\n%d assignment(s) would be made. Dry run; pass --apply to write.\n' "$assigned"
fi
