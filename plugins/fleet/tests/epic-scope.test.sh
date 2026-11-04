#!/usr/bin/env bash
# A cycle acts only on its epic's packages.
#
# The host repo holds two programs, epic #1 and epic #2, each with an
# agent-ready, cell:queued package and no worker yet. The cycle is configured
# for epic #1. What is proved: sync, assign and launch see only epic #1's
# packages; the other program's package keeps its labels, gets no worker and no
# worktree, and its uncollected target repo does not fail the cycle. A package
# whose **Part of** names #1 of another repository is not this epic's.
# `fleet doctor` prints the in-epic and out-of-epic package counts.
set -uo pipefail
cd "$(dirname "$0")"
. ./lib.sh

HERE=$(pwd -P)
FLEET="$(cd .. && pwd -P)/bin/fleet.js"
PLUGIN="$(cd ../../agentic-work-packages && pwd -P)"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
TMP=$(cd "$TMP" && pwd -P)

# --- a real remote and clone --------------------------------------------------
git init -q --bare -b main "$TMP/remote.git"
git clone -q "$TMP/remote.git" "$TMP/clone" 2>/dev/null
git -C "$TMP/clone" checkout -q -b main 2>/dev/null || true
git -C "$TMP/clone" config user.email f@example.invalid; git -C "$TMP/clone" config user.name fixture
printf '# api\n' > "$TMP/clone/README.md"
git -C "$TMP/clone" add -A && git -C "$TMP/clone" commit -qm init && git -C "$TMP/clone" push -q -u origin main
fixture_standards "$TMP/clone" && git -C "$TMP/clone" push -q origin main

# --- stubs -------------------------------------------------------------------
STUB="$TMP/stub"; mkdir -p "$STUB" "$TMP/gh" "$TMP/claude-log"
cp "$HERE/stubs/gh.js" "$STUB/gh.js"
printf '#!/usr/bin/env bash\nexec node "%s/gh.js" "$@"\n' "$STUB" > "$STUB/gh"; chmod +x "$STUB/gh"
cp "$HERE/stubs/claude.sh" "$STUB/claude"; chmod +x "$STUB/claude"
export GH_STUB_DIR="$TMP/gh" GH_STUB_REMOTE="$TMP/remote.git" CLAUDE_STUB_LOG="$TMP/claude-log" CLAUDE_STUB_TARGET="acme/api"
export GH_BIN="$STUB/gh" CLAUDE_BIN="$STUB/claude"
export CLAUDE_CONFIG_FILE="$TMP/claude.json"
node -e "require('fs').writeFileSync('$TMP/claude.json', JSON.stringify({projects:{['$TMP/clone']:{hasTrustDialogAccepted:true}}}))"
unset CLAUDECODE

body() { # part-of repo branch
  printf '**Part of** %s · **Phase 1 · x** · **Repo:** `%s`\n\n## Goal\nx\n\n### SCOPE.json\n```json\n{"feature":"f","branch":"%s","allowedPaths":["src/**"],"dependsOn":[],"execution":{"model":"default","pattern":"solo"}}\n```\n' "$1" "$2" "$3"
}
node - "$TMP/gh" \
  "$(body '#1' acme/api feat/t1-1-first)" \
  "$(body '#2' acme/other feat/u1-1-other)" \
  "$(body 'acme/elsewhere#1' acme/api feat/v1-1-elsewhere)" <<'JS'
const fs = require('fs'); const [dir, t11, u11, v11] = process.argv.slice(2);
fs.writeFileSync(`${dir}/issues.json`, JSON.stringify([
  { number: 1, title: 'Epic: program T', body: '', state: 'OPEN', labels: ['epic'] },
  { number: 2, title: 'Epic: program U', body: '', state: 'OPEN', labels: ['epic'] },
  { number: 10, title: 'T1.1 Epic one package', body: t11, state: 'OPEN', labels: ['agent-ready', 'cell:queued'] },
  // Epic #2's package names a target repo the config does not collect.
  { number: 20, title: 'U1.1 Other program', body: u11, state: 'OPEN', labels: ['agent-ready', 'cell:queued'] },
  // "#1" of another repository is not this host's epic #1.
  { number: 30, title: 'V1.1 Elsewhere', body: v11, state: 'OPEN', labels: ['agent-ready', 'cell:queued'] },
], null, 2));
fs.writeFileSync(`${dir}/prs.json`, '[]');
fs.writeFileSync(`${dir}/labels.json`, '{}'); fs.writeFileSync(`${dir}/comments.json`, '{}'); fs.writeFileSync(`${dir}/writes.log`, '');
JS

cat > "$TMP/fleet.config.json" <<JSON
{
  "repo": "acme/host", "epic": 1,
  "targets": [{ "repo": "acme/api", "localPath": "$TMP/clone", "defaultBranch": "main" }],
  "workers": { "a": { "mode": "local" } },
  "wipCap": 4, "worktreesDir": "$TMP/worktrees", "stateDir": "$TMP/state",
  "pluginRoot": "$PLUGIN", "maxEscalations": 1, "noMovementLimit": 3, "sessionTimeoutMinutes": 5,
  "models": { "cheapest": "haiku", "default": null, "strongest": "opus" }
}
JSON
fleet() { node "$FLEET" "$@" --config "$TMP/fleet.config.json"; }
labels_of() { node -e "const o=require('$TMP/gh/labels.json'); const b=require('$TMP/gh/issues.json').find(i=>i.number===$1); process.stdout.write((o[$1]||b.labels).slice().sort().join(','))"; }

# --- A. dry run: assignment is computed for the epic's packages only ----------
OUT=$(fleet cycle --json 2>"$TMP/errA"); EXIT=$?
assert_eq 0 "$EXIT" "dry run exits 0 (stderr: $(head -c 200 "$TMP/errA" | tr '\n' ' '))"
assigned=$(node -e 'const r=JSON.parse(require("fs").readFileSync(0,"utf8")); process.stdout.write(r.assigned.map(a=>a.number).sort().join(","))' <<< "$OUT")
assert_eq "10" "$assigned" "dry run assigns only epic #1's package"

# --- B. applied cycle ---------------------------------------------------------
OUT=$(fleet cycle --apply --json 2>"$TMP/errB"); EXIT=$?
assert_eq 0 "$EXIT" "applied cycle exits 0: the other epic's uncollected repo does not fail it (stderr: $(head -c 200 "$TMP/errB" | tr '\n' ' '))"
assert_not_contains "$OUT" '"code": "sync-failed"' "no sync-failed alarm"
[ -d "$TMP/worktrees/api-t1-1" ] && _pass "epic #1's package is launched" || _fail "epic #1's package is launched" "no worktree api-t1-1"
[ -d "$TMP/worktrees/other-u1-1" ] && _fail "epic #2's package is not launched" "worktree exists" || _pass "epic #2's package is not launched"
[ -d "$TMP/worktrees/api-v1-1" ] && _fail "another repo's #1 package is not launched" "worktree exists" || _pass "another repo's #1 package is not launched"
assert_empty "$(grep -E '^edit (20|30) ' "$TMP/gh/writes.log")" "no label is written on a package outside the epic"
assert_eq "agent-ready,cell:queued" "$(labels_of 20)" "epic #2's package keeps its labels"
assert_eq "agent-ready,cell:queued" "$(labels_of 30)" "another repo's #1 package keeps its labels"
assert_contains "$(labels_of 10)" "worker:a" "epic #1's package is assigned"
assert_contains "$OUT" '"open": 1' "the report counts only the epic's packages"

# --- C. doctor prints the in-epic and out-of-epic counts -----------------------
OUT=$(fleet doctor 2>&1)
assert_contains "$OUT" "packages of epic #1: 1 open in acme/host, 2 open outside the epic" "doctor prints the in-epic and out-of-epic package counts"

finish
