#!/usr/bin/env bash
# Operator isolation (isolateWorkers, default true). An isolated worker runs
# under --setting-sources project,local, so it reads no user settings, no
# user-enabled plugin and no user instruction file. Its hooks and plugins must
# then come from the target's own .claude/settings.json on the default branch:
#   hooks-missing   enforce-scope or require-handoff is neither wired by path
#                   in a hook command nor provided by agentic-work-packages
#                   enabled in enabledPlugins
#   plugin-missing  a plugin the standards manifest declares is not enabled
# With isolateWorkers false the flag is absent and neither check runs.
#
# Modeled on standards-launch.test.sh: the precondition cases are dry runs,
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
mkdir -p "$TMP/clone/src" "$TMP/clone/.claude"
printf '# api\n' > "$TMP/clone/README.md"
printf 'x\n' > "$TMP/clone/src/index.js"
printf '{"version": 1, "checks": [{"name": "test", "command": "true"}], "rules": []}\n' > "$TMP/clone/.claude/standards.json"
git -C "$TMP/clone" add -A && git -C "$TMP/clone" commit -qm init && git -C "$TMP/clone" push -q -u origin main

# publish <path> <content>: commit one file on main and push. An empty content
# removes the file.
publish() {
  if [ -z "$2" ]; then
    git -C "$TMP/clone" rm -q "$1"
  else
    mkdir -p "$(dirname "$TMP/clone/$1")"
    printf '%s\n' "$2" > "$TMP/clone/$1"
    git -C "$TMP/clone" add "$1"
  fi
  git -C "$TMP/clone" commit -qm "publish $1" && git -C "$TMP/clone" push -q origin main
}
settings() { publish .claude/settings.json "$1"; }
manifest() { publish .claude/standards.json "$1"; }

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

# phase <n> <tag> [top-level-extra-json-fields]: one queued package T1.<n>
# (issue 10+<n>) on branch feat/t1-<n>-<tag>, with fresh state, worktrees and
# claude log, so an applied launch in one phase never shadows the next.
phase() {
  N="$1"; P="$2"; ISSUE=$((10 + N)); ID="T1.$N"; BR="feat/t1-$N-$P"
  export CLAUDE_STUB_LOG="$TMP/claude-log-$P"; mkdir -p "$CLAUDE_STUB_LOG"
  node - "$TMP/gh" "$BR" "$ISSUE" "$ID" <<'JS'
const fs = require('fs'); const [dir, branch, issue, id] = process.argv.slice(2);
const body = '**Part of** #1 · **Phase 1 · x** · **Repo:** `acme/api`\n\n## Goal\nx\n\n### SCOPE.json\n```json\n'
  + JSON.stringify({ feature: 'f', branch, allowedPaths: ['src/**'], forbiddenPaths: [], dependsOn: [], execution: { model: 'default', pattern: 'solo' } })
  + '\n```\n';
fs.writeFileSync(`${dir}/issues.json`, JSON.stringify([
  { number: 1, title: 'Epic: program T', body: '', state: 'OPEN', labels: ['epic'] },
  { number: Number(issue), title: `${id} Isolation`, body, state: 'OPEN', labels: ['agent-ready', 'cell:queued', 'worker:a'] },
], null, 2));
fs.writeFileSync(`${dir}/prs.json`, '[]'); fs.writeFileSync(`${dir}/labels.json`, '{}');
fs.writeFileSync(`${dir}/comments.json`, '{}'); fs.writeFileSync(`${dir}/writes.log`, '');
JS
  cat > "$TMP/fleet.config.json" <<JSON
{
  "repo": "acme/host", "epic": 1,
  "targets": [{ "repo": "acme/api", "localPath": "$TMP/clone", "defaultBranch": "main" }],
  "workers": { "a": { "mode": "local" } },
  "wipCap": 4, "worktreesDir": "$TMP/worktrees-$P", "stateDir": "$TMP/state-$P",
  "pluginRoot": "$PLUGIN", "noMovementLimit": 99 ${3:-}
}
JSON
}
fleet() { node "$FLEET" "$@" --config "$TMP/fleet.config.json"; }

alarms() { printf '%s' "$1" | node -e "const r=JSON.parse(require('fs').readFileSync(0,'utf8')); console.log(r.alarms.filter(a=>a.code===process.argv[1]).map(a=>a.issue).sort().join(' '))" "$2"; }
launched() { printf '%s' "$1" | node -e "const r=JSON.parse(require('fs').readFileSync(0,'utf8')); console.log(r.launched.map(l=>l.issue).sort().join(' '))"; }
detail() { printf '%s' "$1" | node -e "const r=JSON.parse(require('fs').readFileSync(0,'utf8')); console.log(r.alarms.filter(a=>a.code===process.argv[1]).map(a=>a.detail).join(' | '))" "$2"; }

WIRED_BOTH='{"hooks": {
  "PreToolUse": [{"matcher": "Edit|Write", "hooks": [{"type": "command", "command": "node \"$CLAUDE_PROJECT_DIR/.claude/hooks/enforce-scope.js\""}]}],
  "Stop": [{"hooks": [{"type": "command", "command": "node \"$CLAUDE_PROJECT_DIR/.claude/hooks/require-handoff.js\""}]}]}}'
WIRED_SCOPE_ONLY='{"hooks": {
  "PreToolUse": [{"matcher": "Edit|Write", "hooks": [{"type": "command", "command": "node \"$CLAUDE_PROJECT_DIR/.claude/hooks/enforce-scope.js\""}]}]}}'
ENABLED='{"enabledPlugins": {"agentic-work-packages@example-market": true}}'
DISABLED='{"enabledPlugins": {"agentic-work-packages@example-market": false}}'

# --- A. no .claude/settings.json at all: hooks-missing -------------------------
phase 1 nosettings
OUT=$(fleet cycle --json 2>/dev/null)
assert_eq "11" "$(alarms "$OUT" launch-hooks-missing)" "A: a target with no settings file is refused hooks-missing"
assert_empty "$(launched "$OUT")" "A: nothing is launched"
D=$(detail "$OUT" launch-hooks-missing)
assert_contains "$D" "enforce-scope" "A: the alarm names enforce-scope"
assert_contains "$D" "require-handoff" "A: the alarm names require-handoff"
assert_contains "$D" "origin/main" "A: the alarm names the branch it read"
assert_contains "$D" "enabledPlugins" "A: the alarm names the plugin fix"
assert_contains "$D" "agentic-work-packages@" "A: the alarm names the plugin to enable"
assert_contains "$D" "by path" "A: the alarm names the wire-by-path fix"
OUT=$(fleet cycle --apply --json 2>/dev/null)
assert_eq "11" "$(alarms "$OUT" launch-hooks-missing)" "A: the applied cycle refuses too"
[ -d "$TMP/worktrees-nosettings" ] && _fail "A: no worktree is created for a refused launch" "worktrees dir exists" || _pass "A: no worktree is created for a refused launch"
# Read at once: the launch was refused before the spawn, so no detached stub
# exists to write here later.
assert_empty "$(ls "$CLAUDE_STUB_LOG")" "A: no worker was started"

# --- B. settings with neither form: hooks-missing ------------------------------
settings "$DISABLED"
OUT=$(fleet cycle --json 2>/dev/null)
assert_eq "11" "$(alarms "$OUT" launch-hooks-missing)" "B: a plugin set to false is refused hooks-missing"
settings '{"permissions": {"allow": ["Bash(git status:*)"]}}'
OUT=$(fleet cycle --json 2>/dev/null)
assert_eq "11" "$(alarms "$OUT" launch-hooks-missing)" "B: settings with no hooks and no plugin are refused hooks-missing"

# --- C. one hook wired, the other absent: names only the absent one -----------
settings "$WIRED_SCOPE_ONLY"
OUT=$(fleet cycle --json 2>/dev/null)
assert_eq "11" "$(alarms "$OUT" launch-hooks-missing)" "C: one hook wired is still refused"
D=$(detail "$OUT" launch-hooks-missing)
assert_contains "$D" "require-handoff" "C: the alarm names the absent hook"
assert_not_contains "$D" "enforce-scope" "C: the alarm does not name the wired hook"

# --- D. settings that are not JSON: refused, naming the parse failure ---------
settings '{"hooks": '
OUT=$(fleet cycle --json 2>/dev/null)
assert_eq "11" "$(alarms "$OUT" launch-hooks-missing)" "D: unparseable settings are refused hooks-missing"
assert_contains "$(detail "$OUT" launch-hooks-missing)" "not valid JSON" "D: the alarm says the file is not JSON"

# --- E. both hooks wired by path: passes ---------------------------------------
settings "$WIRED_BOTH"
OUT=$(fleet cycle --json 2>/dev/null)
assert_eq "11" "$(launched "$OUT")" "E: hooks wired by path launch"
assert_empty "$(alarms "$OUT" launch-hooks-missing)" "E: no hooks-missing alarm"

# --- F. agentic-work-packages enabled, any marketplace: passes -----------------
settings "$ENABLED"
OUT=$(fleet cycle --json 2>/dev/null)
assert_eq "11" "$(launched "$OUT")" "F: the plugin enabled in project settings launches"
assert_empty "$(alarms "$OUT" launch-hooks-missing)" "F: no hooks-missing alarm"

# --- G. plugin-missing: a declared plugin that is not enabled ------------------
manifest '{"version": 1, "checks": [{"name": "test", "command": "true"}], "rules": [], "plugins": [{"name": "tool-kit", "marketplace": "example-market"}]}'
OUT=$(fleet cycle --json 2>/dev/null)
assert_eq "11" "$(alarms "$OUT" launch-plugin-missing)" "G: a declared plugin not enabled is refused plugin-missing"
assert_empty "$(launched "$OUT")" "G: nothing is launched"
assert_contains "$(detail "$OUT" launch-plugin-missing)" "tool-kit@example-market" "G: the alarm names the plugin"
settings '{"enabledPlugins": {"agentic-work-packages@example-market": true, "tool-kit@other-market": true}}'
OUT=$(fleet cycle --json 2>/dev/null)
assert_eq "11" "$(alarms "$OUT" launch-plugin-missing)" "G: the plugin enabled from another marketplace does not count"
settings '{"enabledPlugins": {"agentic-work-packages@example-market": true, "tool-kit@example-market": true}}'
OUT=$(fleet cycle --json 2>/dev/null)
assert_eq "11" "$(launched "$OUT")" "G: the declared plugin enabled launches"
assert_empty "$(alarms "$OUT" launch-plugin-missing)" "G: no plugin-missing alarm"

# --- H. the applied worker carries --setting-sources project,local ------------
OUT=$(fleet cycle --apply --json 2>/dev/null)
assert_eq "11" "$(launched "$OUT")" "H: the applied cycle launches"
wait_for_file "$CLAUDE_STUB_LOG/T1.1.*.argv"
ARGV=$(cat "$CLAUDE_STUB_LOG"/T1.1.*.argv 2>/dev/null)
assert_contains "$ARGV" $'--setting-sources\nproject,local' "H: the worker's arguments carry --setting-sources project,local by default"

# --- I. isolateWorkers false: no flag, and neither check runs -----------------
settings ""
phase 2 shared ', "isolateWorkers": false'
OUT=$(fleet cycle --json 2>/dev/null)
assert_empty "$(alarms "$OUT" launch-hooks-missing)" "I: hooks-missing is not checked with isolateWorkers false"
assert_empty "$(alarms "$OUT" launch-plugin-missing)" "I: plugin-missing is not checked with isolateWorkers false"
assert_eq "12" "$(launched "$OUT")" "I: a target with no settings file launches"
OUT=$(fleet cycle --apply --json 2>/dev/null)
assert_eq "12" "$(launched "$OUT")" "I: the applied cycle launches"
wait_for_file "$CLAUDE_STUB_LOG/T1.2.*.argv"
ARGV=$(cat "$CLAUDE_STUB_LOG"/T1.2.*.argv 2>/dev/null)
assert_nonempty "$ARGV" "I: the worker was started"
assert_not_contains "$ARGV" "--setting-sources" "I: the worker's arguments do not carry --setting-sources"

# --- J. isolateWorkers is validated --------------------------------------------
for bad in '"yes"' '1' 'null'; do
  phase 3 bad ", \"isolateWorkers\": $bad"
  OUT=$(fleet cycle --json 2>&1); EXIT=$?
  assert_ne 0 "$EXIT" "J: isolateWorkers $bad is a config error"
  assert_contains "$OUT" "isolateWorkers" "J: the error for $bad names the field"
done

finish
