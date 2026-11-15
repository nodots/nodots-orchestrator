#!/usr/bin/env bash
# Instruction leak (isolateWorkers, default true). Claude Code loads CLAUDE.md
# and .claude/CLAUDE.md from every ancestor of the working directory as project
# instructions, so --setting-sources project,local does not keep out a user
# file in an ancestor of the worktree. With isolateWorkers on, launch walks the
# ancestors of the worktree path, from its parent to /, and refuses
# instructions-leak when one holds CLAUDE.md, CLAUDE.local.md or
# .claude/CLAUDE.md. The dry run and fleet doctor report the same check.
#
# Modeled on standards-isolation.test.sh: the precondition cases are dry runs,
# which go through the same launch() checks as applied cycles.
set -uo pipefail
cd "$(dirname "$0")"
. ./lib.sh

HERE=$(pwd -P)
FLEET="$(cd .. && pwd -P)/bin/fleet.js"
PLUGIN="$(cd ../../agentic-work-packages && pwd -P)"
assert_file "$FLEET" "fleet.js exists"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
TMP=$(cd "$TMP" && pwd -P)

git init -q --bare -b main "$TMP/remote.git"
git clone -q "$TMP/remote.git" "$TMP/clone" 2>/dev/null
git -C "$TMP/clone" checkout -q -b main 2>/dev/null || true
git -C "$TMP/clone" config user.email f@example.invalid; git -C "$TMP/clone" config user.name fixture
mkdir -p "$TMP/clone/src"
printf '# api\n' > "$TMP/clone/README.md"
printf 'x\n' > "$TMP/clone/src/index.js"
git -C "$TMP/clone" add -A && git -C "$TMP/clone" commit -qm init
fixture_standards "$TMP/clone" && git -C "$TMP/clone" push -q -u origin main

STUB="$TMP/stub"; mkdir -p "$STUB" "$TMP/gh"
cp "$HERE/stubs/gh.js" "$STUB/gh.js"
printf '#!/usr/bin/env bash\nexec node "%s/gh.js" "$@"\n' "$STUB" > "$STUB/gh"; chmod +x "$STUB/gh"
cp "$HERE/stubs/claude.sh" "$STUB/claude"; chmod +x "$STUB/claude"
export GH_STUB_DIR="$TMP/gh" GH_STUB_REMOTE="$TMP/remote.git" CLAUDE_STUB_TARGET="acme/api"
export GH_BIN="$STUB/gh" CLAUDE_BIN="$STUB/claude"
export CLAUDE_CONFIG_FILE="$TMP/claude.json"
node -e "require('fs').writeFileSync('$TMP/claude.json', JSON.stringify({projects:{['$TMP/clone']:{hasTrustDialogAccepted:true}}}))"
unset CLAUDECODE
printf '{}' > "$TMP/gh/ci.json"

# phase <n> <tag> <worktreesDir> [top-level-extra-json-fields]: one queued
# package T1.<n> (issue 10+<n>) on branch feat/t1-<n>-<tag>, with fresh state
# and claude log, so an applied launch in one phase never shadows the next.
phase() {
  N="$1"; P="$2"; WT="$3"; ISSUE=$((10 + N)); ID="T1.$N"; BR="feat/t1-$N-$P"
  export CLAUDE_STUB_LOG="$TMP/claude-log-$P"; mkdir -p "$CLAUDE_STUB_LOG"
  node - "$TMP/gh" "$BR" "$ISSUE" "$ID" <<'JS'
const fs = require('fs'); const [dir, branch, issue, id] = process.argv.slice(2);
const body = '**Part of** #1 · **Phase 1 · x** · **Repo:** `acme/api`\n\n## Goal\nx\n\n### SCOPE.json\n```json\n'
  + JSON.stringify({ feature: 'f', branch, allowedPaths: ['src/**'], forbiddenPaths: [], dependsOn: [], execution: { model: 'default', pattern: 'solo' } })
  + '\n```\n';
fs.writeFileSync(`${dir}/issues.json`, JSON.stringify([
  { number: 1, title: 'Epic: program T', body: '', state: 'OPEN', labels: ['epic'] },
  { number: Number(issue), title: `${id} Leak`, body, state: 'OPEN', labels: ['agent-ready', 'cell:queued', 'worker:a'] },
], null, 2));
fs.writeFileSync(`${dir}/prs.json`, '[]'); fs.writeFileSync(`${dir}/labels.json`, '{}');
fs.writeFileSync(`${dir}/comments.json`, '{}'); fs.writeFileSync(`${dir}/writes.log`, '');
JS
  cat > "$TMP/fleet.config.json" <<JSON
{
  "repo": "acme/host", "epic": 1,
  "targets": [{ "repo": "acme/api", "localPath": "$TMP/clone", "defaultBranch": "main" }],
  "workers": { "a": { "mode": "local" } },
  "wipCap": 4, "worktreesDir": "$WT", "stateDir": "$TMP/state-$P",
  "pluginRoot": "$PLUGIN", "noMovementLimit": 99 ${4:-}
}
JSON
}
fleet() { node "$FLEET" "$@" --config "$TMP/fleet.config.json"; }

alarms() { printf '%s' "$1" | node -e "const r=JSON.parse(require('fs').readFileSync(0,'utf8')); console.log(r.alarms.filter(a=>a.code===process.argv[1]).map(a=>a.issue).sort().join(' '))" "$2"; }
launched() { printf '%s' "$1" | node -e "const r=JSON.parse(require('fs').readFileSync(0,'utf8')); console.log(r.launched.map(l=>l.issue).sort().join(' '))"; }
detail() { printf '%s' "$1" | node -e "const r=JSON.parse(require('fs').readFileSync(0,'utf8')); console.log(r.alarms.filter(a=>a.code===process.argv[1]).map(a=>a.detail).join(' | '))" "$2"; }
doctor_line() { fleet doctor 2>/dev/null | grep 'instruction file'; }

# Fixture trees. Each worktreesDir sits two levels below the directory that
# holds the instruction file, so the walk goes past the parent.
mkdir -p "$TMP/leak-dot/.claude" "$TMP/leak-md" "$TMP/leak-local" "$TMP/clean"
printf '# user\n' > "$TMP/leak-dot/.claude/CLAUDE.md"
printf '# user\n' > "$TMP/leak-md/CLAUDE.md"
printf '# user\n' > "$TMP/leak-local/CLAUDE.local.md"

# --- A. .claude/CLAUDE.md in an ancestor: refused instructions-leak ------------
phase 1 dot "$TMP/leak-dot/a/worktrees"
OUT=$(fleet cycle --json 2>/dev/null)
assert_eq "11" "$(alarms "$OUT" launch-instructions-leak)" "A: .claude/CLAUDE.md in an ancestor is refused instructions-leak in the dry run"
assert_empty "$(launched "$OUT")" "A: nothing is launched"
D=$(detail "$OUT" launch-instructions-leak)
assert_contains "$D" "$TMP/leak-dot/.claude/CLAUDE.md" "A: the alarm names the file"
assert_contains "$D" "worktreesDir" "A: the alarm names the worktreesDir fix"
assert_contains "$D" "isolateWorkers" "A: the alarm names the isolateWorkers fix"
OUT=$(fleet cycle --apply --json 2>/dev/null)
assert_eq "11" "$(alarms "$OUT" launch-instructions-leak)" "A: the applied cycle refuses too"
[ -d "$TMP/leak-dot/a/worktrees" ] && _fail "A: no worktree is created for a refused launch" "worktrees dir exists" || _pass "A: no worktree is created for a refused launch"
assert_empty "$(ls "$CLAUDE_STUB_LOG")" "A: no worker was started"
L=$(doctor_line)
assert_contains "$L" "FAIL" "A: doctor fails the check"
assert_contains "$L" "$TMP/leak-dot/.claude/CLAUDE.md" "A: doctor names the file"

# --- B. CLAUDE.md in an ancestor: refused ---------------------------------------
phase 2 md "$TMP/leak-md/a/worktrees"
OUT=$(fleet cycle --json 2>/dev/null)
assert_eq "11" "$(alarms "$OUT" launch-instructions-leak)" "B: CLAUDE.md in an ancestor is refused instructions-leak"
assert_contains "$(detail "$OUT" launch-instructions-leak)" "$TMP/leak-md/CLAUDE.md" "B: the alarm names the file"
assert_empty "$(launched "$OUT")" "B: nothing is launched"

# --- C. CLAUDE.local.md in an ancestor: refused ---------------------------------
phase 3 local "$TMP/leak-local/a/worktrees"
OUT=$(fleet cycle --json 2>/dev/null)
assert_eq "11" "$(alarms "$OUT" launch-instructions-leak)" "C: CLAUDE.local.md in an ancestor is refused instructions-leak"
assert_contains "$(detail "$OUT" launch-instructions-leak)" "$TMP/leak-local/CLAUDE.local.md" "C: the alarm names the file"
assert_empty "$(launched "$OUT")" "C: nothing is launched"

# --- D. two files in the chain: the alarm names each ----------------------------
mkdir -p "$TMP/leak-md/a/.claude"; printf '# user\n' > "$TMP/leak-md/a/.claude/CLAUDE.md"
phase 4 two "$TMP/leak-md/a/worktrees"
OUT=$(fleet cycle --json 2>/dev/null)
D=$(detail "$OUT" launch-instructions-leak)
assert_contains "$D" "$TMP/leak-md/CLAUDE.md" "D: the alarm names the upper file"
assert_contains "$D" "$TMP/leak-md/a/.claude/CLAUDE.md" "D: the alarm names the lower file"

# --- E. no instruction file in any ancestor: launches ---------------------------
phase 5 clean "$TMP/clean/a/worktrees"
OUT=$(fleet cycle --json 2>/dev/null)
assert_empty "$(alarms "$OUT" launch-instructions-leak)" "E: no instructions-leak alarm"
assert_eq "15" "$(launched "$OUT")" "E: a worktree with no such ancestor launches in the dry run"
OUT=$(fleet cycle --apply --json 2>/dev/null)
assert_eq "15" "$(launched "$OUT")" "E: the applied cycle launches"
assert_nonempty "$(cat "$CLAUDE_STUB_LOG"/T1.5.*.argv 2>/dev/null)" "E: the worker was started"
L=$(doctor_line)
assert_contains "$L" "ok" "E: doctor passes the check"
assert_not_contains "$L" "FAIL" "E: doctor does not fail the check"

# --- F. isolateWorkers false: the check does not run ----------------------------
phase 6 off "$TMP/leak-dot/b/worktrees" ', "isolateWorkers": false'
OUT=$(fleet cycle --json 2>/dev/null)
assert_empty "$(alarms "$OUT" launch-instructions-leak)" "F: instructions-leak is not checked with isolateWorkers false"
assert_eq "16" "$(launched "$OUT")" "F: the dry run launches"
OUT=$(fleet cycle --apply --json 2>/dev/null)
assert_eq "16" "$(launched "$OUT")" "F: the applied cycle launches"
assert_nonempty "$(cat "$CLAUDE_STUB_LOG"/T1.6.*.argv 2>/dev/null)" "F: the worker was started"
L=$(doctor_line)
assert_not_contains "$L" "FAIL" "F: doctor does not fail the check with isolateWorkers false"
assert_contains "$L" "isolateWorkers" "F: doctor says why the check is skipped"

finish
