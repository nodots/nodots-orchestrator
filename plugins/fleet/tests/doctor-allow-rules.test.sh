#!/usr/bin/env bash
# Broad allow rules. fleet doctor reads each target's .claude/settings.json on
# origin/<defaultBranch> and prints one WARN line per permissions.allow rule
# that is a wildcard over an interpreter or container runtime: Bash(<name> *)
# or Bash(<name>:*). The line names the rule and says why it is broad. A WARN
# is not a FAIL: doctor's exit code is the same with or without broad rules,
# and a launch is not refused for one.
#
# Fixture: main carries Bash(node *), Bash(docker *) and Bash(git status:*);
# the working tree adds an uncommitted Bash(python:*), which doctor must not
# read, because a worker is cut from the branch, not from the clone's tree.
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
printf '# api\n' > "$TMP/clone/README.md"
git -C "$TMP/clone" add -A && git -C "$TMP/clone" commit -qm init
fixture_standards "$TMP/clone" && git -C "$TMP/clone" push -q -u origin main

# settings <allow rules as a JSON array>: commit and push project settings that
# keep the fixture's enabled plugin and carry these allow rules.
settings() {
  printf '{"enabledPlugins": {"agentic-work-packages@example-market": true}, "permissions": {"allow": %s}}\n' "$1" > "$TMP/clone/.claude/settings.json"
  git -C "$TMP/clone" add .claude/settings.json && git -C "$TMP/clone" commit -qm "fixture: allow rules" && git -C "$TMP/clone" push -q origin main
}

STUB="$TMP/stub"; mkdir -p "$STUB" "$TMP/gh" "$TMP/claude-log"
cp "$HERE/stubs/gh.js" "$STUB/gh.js"
printf '#!/usr/bin/env bash\nexec node "%s/gh.js" "$@"\n' "$STUB" > "$STUB/gh"; chmod +x "$STUB/gh"
cp "$HERE/stubs/claude.sh" "$STUB/claude"; chmod +x "$STUB/claude"
export GH_STUB_DIR="$TMP/gh" GH_STUB_REMOTE="$TMP/remote.git" CLAUDE_STUB_LOG="$TMP/claude-log" CLAUDE_STUB_TARGET="acme/api"
export GH_BIN="$STUB/gh" CLAUDE_BIN="$STUB/claude"
export CLAUDE_CONFIG_FILE="$TMP/claude.json"
node -e "require('fs').writeFileSync('$TMP/claude.json', JSON.stringify({projects:{['$TMP/clone']:{hasTrustDialogAccepted:true}}}))"
unset CLAUDECODE

node - "$TMP/gh" <<'JS'
const fs = require('fs'); const [dir] = process.argv.slice(2);
const body = '**Part of** #1 · **Phase 1 · x** · **Repo:** `acme/api`\n\n## Goal\nx\n\n### SCOPE.json\n```json\n'
  + JSON.stringify({ feature: 'f', branch: 'feat/t1-1-web', allowedPaths: ['src/**'], forbiddenPaths: [], dependsOn: [], execution: { model: 'default', pattern: 'solo' } })
  + '\n```\n';
fs.writeFileSync(`${dir}/issues.json`, JSON.stringify([
  { number: 1, title: 'Epic: program T', body: '', state: 'OPEN', labels: ['epic'] },
  { number: 10, title: 'T1.1 Web', body, state: 'OPEN', labels: ['agent-ready', 'cell:queued', 'worker:a'] },
], null, 2));
fs.writeFileSync(`${dir}/prs.json`, '[]'); fs.writeFileSync(`${dir}/labels.json`, '{}');
fs.writeFileSync(`${dir}/comments.json`, '{}'); fs.writeFileSync(`${dir}/writes.log`, '');
JS
printf '{}' > "$TMP/gh/ci.json"

cat > "$TMP/fleet.config.json" <<JSON
{
  "repo": "acme/host", "epic": 1,
  "targets": [{ "repo": "acme/api", "localPath": "$TMP/clone", "defaultBranch": "main" }],
  "workers": { "a": { "mode": "local" } },
  "wipCap": 4, "worktreesDir": "$TMP/worktrees", "stateDir": "$TMP/state",
  "pluginRoot": "$PLUGIN", "noMovementLimit": 99
}
JSON
fleet() { node "$FLEET" "$@" --config "$TMP/fleet.config.json"; }
launched() { printf '%s' "$1" | node -e "const r=JSON.parse(require('fs').readFileSync(0,'utf8')); console.log(r.launched.map(l=>l.issue).sort().join(' '))"; }

# --- A. narrow rules only: no WARN line ------------------------------------------
settings '["Bash(git status:*)", "Bash(node plugins/*)", "Bash(bash scripts/*)"]'
OUT=$(fleet doctor 2>/dev/null); NARROW_EXIT=$?
assert_empty "$(printf '%s\n' "$OUT" | grep '^WARN')" "A: narrow rules draw no WARN line"

# --- B. the package fixture: node and docker warn, git status does not -----------
settings '["Bash(node *)", "Bash(docker *)", "Bash(git status:*)"]'
printf '{"permissions": {"allow": ["Bash(node *)", "Bash(docker *)", "Bash(git status:*)", "Bash(python:*)"]}}\n' > "$TMP/clone/.claude/settings.json"
OUT=$(fleet doctor 2>/dev/null); BROAD_EXIT=$?
WARN=$(printf '%s\n' "$OUT" | grep '^WARN')
assert_eq "2" "$(printf '%s\n' "$WARN" | grep -c .)" "B: two WARN lines"
assert_contains "$WARN" "Bash(node *)" "B: a WARN line names Bash(node *)"
assert_contains "$WARN" "Bash(docker *)" "B: a WARN line names Bash(docker *)"
assert_not_contains "$WARN" "git status" "B: Bash(git status:*) draws no WARN line"
assert_not_contains "$WARN" "python" "B: the uncommitted working-tree rule is not read"
assert_contains "$(printf '%s\n' "$WARN" | grep 'Bash(node \*)')" "acme/api" "B: the WARN line names the target"
assert_contains "$(printf '%s\n' "$WARN" | grep 'Bash(node \*)')" "any command" "B: the WARN line says why the rule is broad"
assert_contains "$(printf '%s\n' "$WARN" | grep 'Bash(node \*)')" "origin/main" "B: the WARN line names the ref it read"
assert_empty "$(printf '%s\n' "$OUT" | grep '^FAIL' | grep -i 'allow')" "B: no FAIL line for an allow rule"
assert_eq "$NARROW_EXIT" "$BROAD_EXIT" "B: a WARN does not change doctor's exit code"
git -C "$TMP/clone" checkout -q -- .claude/settings.json

# --- C. both wildcard forms, every listed name, and near misses ------------------
settings '["Bash(node:*)", "Bash(python3 *)", "Bash(sh:*)", "Bash(npx *)", "Bash(psql:*)", "Bash(nodemon *)", "Bash(node plugins/*)", "Bash(docker ps:*)", "Read(node *)"]'
WARN=$(fleet doctor 2>/dev/null | grep '^WARN')
assert_eq "5" "$(printf '%s\n' "$WARN" | grep -c .)" "C: five WARN lines"
for r in 'Bash(node:*)' 'Bash(python3 *)' 'Bash(sh:*)' 'Bash(npx *)' 'Bash(psql:*)'; do
  assert_contains "$WARN" "$r" "C: $r warns"
done
for r in 'nodemon' 'node plugins' 'docker ps' 'Read('; do
  assert_not_contains "$WARN" "$r" "C: $r does not warn"
done

# --- D. a broad rule does not refuse a launch ------------------------------------
OUT=$(fleet cycle --json 2>/dev/null)
assert_eq "10" "$(launched "$OUT")" "D: the dry run still launches with broad rules on main"

# --- E. no settings on the branch, and unreadable settings -----------------------
git -C "$TMP/clone" rm -q .claude/settings.json && git -C "$TMP/clone" commit -qm "fixture: no settings" && git -C "$TMP/clone" push -q origin main
assert_empty "$(fleet doctor 2>/dev/null | grep '^WARN')" "E: no settings file on the branch draws no WARN line"
mkdir -p "$TMP/clone/.claude"; printf '{not json\n' > "$TMP/clone/.claude/settings.json"
git -C "$TMP/clone" add .claude/settings.json && git -C "$TMP/clone" commit -qm "fixture: bad settings" && git -C "$TMP/clone" push -q origin main
L=$(fleet doctor 2>/dev/null | grep '^WARN')
assert_contains "$L" "cannot be read" "E: settings that are not JSON draw a WARN that says the rules were not checked"
assert_contains "$L" "acme/api" "E: that WARN names the target"

finish
