#!/usr/bin/env bash
# SV1 gate: the init command, the launcher and the validator agree on one
# manifest end to end. `fleet standards init --write` drafts a manifest from a
# fixture clone's package.json and CLAUDE.md; once it is pushed, the launcher
# accepts it and briefs the worker from it, refuses the launch when it is
# removed or carries an unknown key, and launches with no standards lines when
# the target's standards is "off".
#
# Modeled on ci-preconditions.test.sh. Each phase has its own package, state,
# worktrees and claude log, so an earlier launch never shadows a later
# refusal. The gate edits nothing it verifies.
set -uo pipefail
cd "$(dirname "$0")"
. ./lib.sh

HERE=$(pwd -P)
FLEET="$(cd .. && pwd -P)/bin/fleet.js"
PLUGIN="$(cd ../../agentic-work-packages && pwd -P)"
CHECK="$PLUGIN/skills/agentic-work-packages/assets/scripts/check-standards.js"
assert_file "$FLEET" "fleet.js exists"
assert_file "$CHECK" "check-standards.js exists"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
TMP=$(cd "$TMP" && pwd -P)

# A fixture clone with a package.json and a CLAUDE.md, and nothing else the
# draft could read.
git init -q --bare -b main "$TMP/remote.git"
git clone -q "$TMP/remote.git" "$TMP/clone" 2>/dev/null
git -C "$TMP/clone" checkout -q -b main 2>/dev/null || true
git -C "$TMP/clone" config user.email f@example.invalid; git -C "$TMP/clone" config user.name fixture
mkdir -p "$TMP/clone/src"
cat > "$TMP/clone/package.json" <<'JSON'
{ "name": "api", "scripts": { "test": "node t.js", "lint": "eslint .", "start": "node ." } }
JSON
printf '# api rules\n' > "$TMP/clone/CLAUDE.md"
printf 'x\n' > "$TMP/clone/src/index.js"
# Project settings, so an isolated launch (isolateWorkers) is not refused
# hooks-missing.
mkdir -p "$TMP/clone/.claude"
printf '{"enabledPlugins": {"agentic-work-packages@example-market": true}}\n' > "$TMP/clone/.claude/settings.json"
git -C "$TMP/clone" add -A && git -C "$TMP/clone" commit -qm init && git -C "$TMP/clone" push -q -u origin main

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

# phase <n> <tag> [target-extra-json-fields]: one queued package T1.<n>
# (issue 10+<n>) on branch feat/t1-<n>-<tag>, with fresh state, worktrees and
# claude log. A distinct package per phase: the label sync derives a package's
# cell from a pushed branch carrying its id, so a reused id reads as active.
phase() {
  N="$1"; P="$2"; ISSUE=$((10 + N)); ID="T1.$N"; BR="feat/t1-$N-$P"
  WT="$TMP/worktrees-$P"; ST="$TMP/state-$P"
  export CLAUDE_STUB_LOG="$TMP/claude-log-$P"; mkdir -p "$CLAUDE_STUB_LOG"
  node - "$TMP/gh" "$BR" "$ISSUE" "$ID" <<'JS'
const fs = require('fs'); const [dir, branch, issue, id] = process.argv.slice(2);
const body = '**Part of** #1 · **Phase 1 · x** · **Repo:** `acme/api`\n\n## Goal\nx\n\n### SCOPE.json\n```json\n'
  + JSON.stringify({ feature: 'f', branch, allowedPaths: ['src/**'], forbiddenPaths: [], dependsOn: [], execution: { model: 'default', pattern: 'solo' } })
  + '\n```\n';
fs.writeFileSync(`${dir}/issues.json`, JSON.stringify([
  { number: 1, title: 'Epic: program T', body: '', state: 'OPEN', labels: ['epic'] },
  { number: Number(issue), title: `${id} Gate`, body, state: 'OPEN', labels: ['agent-ready', 'cell:queued', 'worker:a'] },
], null, 2));
fs.writeFileSync(`${dir}/prs.json`, '[]'); fs.writeFileSync(`${dir}/labels.json`, '{}');
fs.writeFileSync(`${dir}/comments.json`, '{}'); fs.writeFileSync(`${dir}/writes.log`, '');
JS
  cat > "$TMP/fleet.config.json" <<JSON
{
  "repo": "acme/host", "epic": 1,
  "targets": [{ "repo": "acme/api", "localPath": "$TMP/clone", "defaultBranch": "main" ${3:-} }],
  "workers": { "a": { "mode": "local" } },
  "wipCap": 4, "worktreesDir": "$WT", "stateDir": "$ST",
  "pluginRoot": "$PLUGIN", "noMovementLimit": 99
}
JSON
}
fleet() { node "$FLEET" "$@" --config "$TMP/fleet.config.json"; }

# alarms <json> <code> -> the issue numbers carrying that alarm code
alarms() { printf '%s' "$1" | node -e "const r=JSON.parse(require('fs').readFileSync(0,'utf8')); console.log(r.alarms.filter(a=>a.code===process.argv[1]).map(a=>a.issue).sort().join(' '))" "$2"; }
# launched <json> -> the issue numbers launched
launched() { printf '%s' "$1" | node -e "const r=JSON.parse(require('fs').readFileSync(0,'utf8')); console.log(r.launched.map(l=>l.issue).sort().join(' '))"; }
# detail <json> <code> -> the alarm detail text for that code
detail() { printf '%s' "$1" | node -e "const r=JSON.parse(require('fs').readFileSync(0,'utf8')); console.log(r.alarms.filter(a=>a.code===process.argv[1]).map(a=>a.detail).join(' | '))" "$2"; }
# standards_alarms <json> -> the launch-standards-* alarm codes
standards_alarms() { printf '%s' "$1" | node -e "const r=JSON.parse(require('fs').readFileSync(0,'utf8')); console.log(r.alarms.filter(a=>a.code.startsWith('launch-standards')).map(a=>a.code).join(' '))"; }
# standards <json> -> this phase's launched row's standards record, as JSON
standards() { printf '%s' "$1" | node -e "const r=JSON.parse(require('fs').readFileSync(0,'utf8')); const l=r.launched.find(x=>x.issue===Number(process.argv[1])); console.log(JSON.stringify(l ? l.standards : null))" "$ISSUE"; }
# manifest_field <file> <expr> -> JSON.stringify of the expression over the manifest m
manifest_field() { node -e "const m=JSON.parse(require('fs').readFileSync(process.argv[1],'utf8')); console.log(JSON.stringify(eval(process.argv[2])))" "$1" "$2"; }
no_worktree() { # label
  if [ -d "$WT" ]; then _fail "$1" "$WT exists"; else _pass "$1"; fi
}

MANIFEST="$TMP/clone/.claude/standards.json"

# --- 1. draft -> push -> dry run: launched with the drafted checks ------------
phase 1 draft
fleet standards init --target acme/api --write >/dev/null 2>"$TMP/init.err"
assert_eq 0 "$?" "1: fleet standards init --write exits 0 for the fixture clone"
assert_file "$MANIFEST" "1: init wrote .claude/standards.json"
node "$CHECK" --root "$TMP/clone" >/dev/null 2>&1
assert_eq 0 "$?" "1: check-standards.js accepts the drafted manifest"
NAMES=$(manifest_field "$MANIFEST" 'm.checks.map(c => c.name)')
assert_eq '["lint","test"]' "$NAMES" "1: the draft's checks are lint and test, from package.json"
assert_eq '[{"doc":"CLAUDE.md","check":null}]' "$(manifest_field "$MANIFEST" 'm.rules')" "1: the draft's one rule is CLAUDE.md"
git -C "$TMP/clone" add .claude/standards.json && git -C "$TMP/clone" commit -qm "standards: drafted by fleet standards init" && git -C "$TMP/clone" push -q origin main
assert_eq "$(git -C "$TMP/clone" rev-parse HEAD)" "$(git --git-dir "$TMP/remote.git" rev-parse main)" "1: the drafted manifest is pushed to main"
OUT=$(fleet cycle --json 2>/dev/null)
assert_eq "$ISSUE" "$(launched "$OUT")" "1: the dry run launches on the drafted manifest"
assert_empty "$(standards_alarms "$OUT")" "1: no standards alarm"
assert_eq "{\"checks\":$NAMES,\"rules\":1,\"applicable\":1}" "$(standards "$OUT")" "1: the standards record names the drafted checks"
TEXT=$(fleet cycle 2>/dev/null)
assert_contains "$TEXT" "on $BR · standards: lint, test (1 of 1 rules in lane)" "1: the report line names the drafted checks"
no_worktree "1: the dry run creates no worktree"

# --- 2. applied cycle: the prompt names each drafted command and the rule -----
phase 2 applied
OUT=$(fleet cycle --apply --json 2>/dev/null)
assert_eq "$ISSUE" "$(launched "$OUT")" "2: the applied cycle launches"
assert_eq "{\"checks\":$NAMES,\"rules\":1,\"applicable\":1}" "$(standards "$OUT")" "2: the applied row carries the same standards record"
wait_for_file "$CLAUDE_STUB_LOG/$ID.*.argv"
ARGV=$(cat "$CLAUDE_STUB_LOG"/"$ID".*.argv 2>/dev/null)
assert_nonempty "$ARGV" "2: the worker was started"
assert_contains "$ARGV" "Standards for acme/api are in .claude/standards.json in this worktree." "2: the prompt points at the manifest"
COUNT=0
while IFS= read -r line; do
  [ -z "$line" ] && continue
  COUNT=$((COUNT + 1))
  assert_contains "$ARGV" "$line" "2: the prompt names the drafted check [$line]"
done < <(node -e "for (const c of JSON.parse(require('fs').readFileSync(process.argv[1],'utf8')).checks) console.log(c.name + ': ' + c.command)" "$MANIFEST")
assert_eq 2 "$COUNT" "2: every drafted check was looked for"
assert_contains "$ARGV" "test: npm test" "2: the drafted test command is npm test"
assert_contains "$ARGV" "lint: npm run lint" "2: the drafted lint command is npm run lint"
assert_contains "$ARGV" "Rules for your lane; read each doc before changing code under its paths: CLAUDE.md (all paths)" "2: the prompt names the CLAUDE.md rule"

# --- 3. manifest removed on main: standards-missing, no worktree --------------
phase 3 missing
git -C "$TMP/clone" rm -q .claude/standards.json && git -C "$TMP/clone" commit -qm "standards: removed" && git -C "$TMP/clone" push -q origin main
OUT=$(fleet cycle --apply --json 2>/dev/null)
assert_eq "$ISSUE" "$(alarms "$OUT" launch-standards-missing)" "3: the applied cycle refuses standards-missing"
assert_empty "$(launched "$OUT")" "3: nothing is launched"
assert_contains "$(detail "$OUT" launch-standards-missing)" "acme/api has no .claude/standards.json on origin/main" "3: the alarm names the manifest and the branch"
no_worktree "3: no worktree is created"
# Read at once, here and in 4: the launch was refused before the spawn, so no
# detached stub exists to write here later.
assert_empty "$(ls "$CLAUDE_STUB_LOG")" "3: no worker was started"
assert_empty "$(git --git-dir "$TMP/remote.git" for-each-ref --format='%(refname:short)' refs/heads | grep -x "$BR")" "3: no branch was pushed"
TEXT=$(fleet cycle --apply 2>/dev/null)
assert_contains "$TEXT" "- launch-standards-missing (#$ISSUE): acme/api has no .claude/standards.json on origin/main" "3: the report's alarms say so"
assert_not_contains "$TEXT" "**Launched**" "3: the report launches nothing"
no_worktree "3: the second applied cycle creates no worktree either"

# --- 4. a manifest with an unknown key: standards-invalid naming it -----------
phase 4 invalid
git -C "$TMP/clone" show HEAD~1:.claude/standards.json > "$TMP/drafted.json"
mkdir -p "$TMP/clone/.claude"
node -e "const fs=require('fs'); const m=JSON.parse(fs.readFileSync(process.argv[1],'utf8')); m.reviewers=['x']; fs.writeFileSync(process.argv[2], JSON.stringify(m, null, 2)+'\n')" "$TMP/drafted.json" "$MANIFEST"
git -C "$TMP/clone" add .claude/standards.json && git -C "$TMP/clone" commit -qm "standards: unknown key" && git -C "$TMP/clone" push -q origin main
OUT=$(fleet cycle --apply --json 2>/dev/null)
assert_eq "$ISSUE" "$(alarms "$OUT" launch-standards-invalid)" "4: a manifest with an unknown key is refused standards-invalid"
assert_empty "$(launched "$OUT")" "4: nothing is launched"
assert_contains "$(detail "$OUT" launch-standards-invalid)" "reviewers: unknown key" "4: the alarm names the unknown key"
no_worktree "4: no worktree is created"
assert_empty "$(ls "$CLAUDE_STUB_LOG")" "4: no worker was started"

# --- 5. standards "off": launched, reported off, no standards lines -----------
phase 5 off ', "standards": "off"'
OUT=$(fleet cycle --json 2>/dev/null)
assert_eq "$ISSUE" "$(launched "$OUT")" "5: standards off launches past the invalid manifest"
assert_empty "$(standards_alarms "$OUT")" "5: no standards alarm"
assert_eq '"off"' "$(standards "$OUT")" "5: the dry-run row records standards off"
TEXT=$(fleet cycle 2>/dev/null)
assert_contains "$TEXT" "on $BR · standards: off" "5: the report line says standards: off"
OUT=$(fleet cycle --apply --json 2>/dev/null)
assert_eq "$ISSUE" "$(launched "$OUT")" "5: the applied cycle launches"
wait_for_file "$CLAUDE_STUB_LOG/$ID.*.argv"
ARGV=$(cat "$CLAUDE_STUB_LOG"/"$ID".*.argv 2>/dev/null)
assert_nonempty "$ARGV" "5: the worker was started"
assert_not_contains "$ARGV" "Standards for" "5: the prompt carries no standards line"
assert_not_contains "$ARGV" "Rules for your lane" "5: nor a rules line"
assert_not_contains "$ARGV" "names paths in your lane" "5: nor the no-rule line"

finish
