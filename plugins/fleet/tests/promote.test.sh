#!/usr/bin/env bash
# Fixture test for src/promote.js: cell:queued is added exactly when every
# dependsOn branch has a merged PR, the package is agent-ready, carries no
# cell:* label yet, has no branch, and has a launchable SCOPE.json.
set -uo pipefail
cd "$(dirname "$0")"
. ./lib.sh

SRC="$(cd .. && pwd -P)/src/promote.js"
assert_file "$SRC" "promote.js exists"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

OUT=$(node - "$SRC" <<'JS'
const { promote } = require(process.argv[2]);
const body = (branch, deps) => '**Repo:** `acme/api`\n\n### SCOPE.json\n```json\n' + JSON.stringify({ branch, allowedPaths: ['src/**'], dependsOn: deps }) + '\n```\n';
const issues = [
  { number: 1, title: 'A1.0 schema', state: 'OPEN', labels: ['agent-ready', 'cell:active'], body: body('feat/a1-0', []) },
  { number: 2, title: 'A1.1 dep met', state: 'OPEN', labels: ['agent-ready'], body: body('feat/a1-1', ['feat/a0-9']) },
  { number: 3, title: 'A1.2 dep unmet', state: 'OPEN', labels: ['agent-ready'], body: body('feat/a1-2', ['feat/a1-0']) },
  { number: 4, title: 'A1.3 no deps', state: 'OPEN', labels: ['agent-ready'], body: body('feat/a1-3', []) },
  { number: 5, title: 'A1.4 not ready', state: 'OPEN', labels: [], body: body('feat/a1-4', []) },
  { number: 6, title: 'A1.5 closed', state: 'CLOSED', labels: ['agent-ready'], body: body('feat/a1-5', []) },
  { number: 7, title: 'A1.6 bad scope', state: 'OPEN', labels: ['agent-ready'], body: 'no block' },
  { number: 8, title: 'A1.7 branch exists', state: 'OPEN', labels: ['agent-ready'], body: body('feat/a1-7', []) },
  { number: 9, title: 'A1.8 two deps one unmet', state: 'OPEN', labels: ['agent-ready'], body: body('feat/a1-8', ['feat/a0-9', 'feat/a1-0']) },
];
const sync = { repo: 'acme/host', targets: ['acme/api'], issues: [
  { number: 90, title: 'A0.9 done', label: 'cell:merged', branch: 'feat/a0-9', branchExists: true, blockerOnBranch: false, pr: { number: 900, state: 'MERGED', headSha: 'x', comments: [] } },
  { number: 1, title: 'A1.0 schema', label: 'cell:active', branch: 'feat/a1-0', branchExists: true, blockerOnBranch: false, pr: null },
  { number: 8, title: 'A1.7 branch exists', label: 'cell:queued', branch: 'feat/a1-7', branchExists: true, blockerOnBranch: false, pr: null },
] };
const out = promote(issues, sync);
const edits = out.edits.map(e => e.number).join(',');
const held = Object.fromEntries(out.held.map(h => [h.number, h.why]));
console.log(edits);
console.log(JSON.stringify(held));
JS
)
EDITS=$(printf '%s\n' "$OUT" | sed -n 1p)
HELD=$(printf '%s\n' "$OUT" | sed -n 2p)

assert_eq "2,4" "$EDITS" "only the dep-met and no-dep packages are promoted (not active, not closed, not unready, not bad, not branched, not half-met)"
assert_contains "$HELD" '"3":"waiting on feat/a1-0"' "an unmet dependency is named"
assert_contains "$HELD" '"9":"waiting on feat/a1-0"' "with two deps only the unmet one is named"
assert_contains "$HELD" '"7":"not promotable' "a package without a valid SCOPE.json is held and says why"
assert_contains "$HELD" '"8":"branch or PR already exists' "a package whose branch exists is left to sync"
assert_not_contains "$HELD" '"1":' "a package already in the lifecycle is neither promoted nor held"
assert_not_contains "$HELD" '"5":' "a package without agent-ready is ignored, not held"

finish
