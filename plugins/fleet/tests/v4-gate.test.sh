#!/usr/bin/env bash
# V4 gate, fleet half: an unattended launch is refused when the target repo's CI
# is disabled, and when a cheapest-tier package names no execution.verifiedBy.
#
# Both cases run applied cycles, so a refusal is checked by what did not
# happen: no worktree, no worker started, no branch pushed.
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
git -C "$TMP/clone" add -A && git -C "$TMP/clone" commit -qm init && git -C "$TMP/clone" push -q -u origin main
fixture_standards "$TMP/clone" && git -C "$TMP/clone" push -q origin main

STUB="$TMP/stub"; mkdir -p "$STUB" "$TMP/gh"
cp "$HERE/stubs/gh.js" "$STUB/gh.js"
printf '#!/usr/bin/env bash\nexec node "%s/gh.js" "$@"\n' "$STUB" > "$STUB/gh"; chmod +x "$STUB/gh"
cp "$HERE/stubs/claude.sh" "$STUB/claude"; chmod +x "$STUB/claude"
export GH_STUB_DIR="$TMP/gh" GH_STUB_REMOTE="$TMP/remote.git" CLAUDE_STUB_LOG="$TMP/claude-log" CLAUDE_STUB_TARGET="acme/api"
export GH_BIN="$STUB/gh" CLAUDE_BIN="$STUB/claude"
export CLAUDE_CONFIG_FILE="$TMP/claude.json"
node -e "require('fs').writeFileSync('$TMP/claude.json', JSON.stringify({projects:{['$TMP/clone']:{hasTrustDialogAccepted:true}}}))"
unset CLAUDECODE

scope_body() { # branch execution-json
  printf '**Part of** #1 · **Phase 1 · x** · **Repo:** `acme/api`\n\n## Goal\nx\n\n### SCOPE.json\n```json\n{"feature":"f","branch":"%s","allowedPaths":["src/**"],"forbiddenPaths":[],"dependsOn":[],"execution":%s}\n```\n' "$1" "$2"
}
node - "$TMP/gh" \
  "$(scope_body feat/g9-1-default '{"model":"default","pattern":"solo"}')" \
  "$(scope_body feat/g9-2-cheap-bare '{"model":"cheapest","pattern":"solo"}')" \
  "$(scope_body feat/g9-3-cheap-verified '{"model":"cheapest","pattern":"solo","verifiedBy":"bash tests/run.sh"}')" <<'JS'
const fs = require('fs'); const [dir, b1, b2, b3] = process.argv.slice(2);
const q = (number, title, body) => ({ number, title, body, state: 'OPEN', labels: ['agent-ready', 'cell:queued', 'worker:a'] });
fs.writeFileSync(`${dir}/issues.json`, JSON.stringify([
  { number: 1, title: 'Epic: program G', body: '', state: 'OPEN', labels: ['epic'] },
  q(20, 'G9.1 Default tier', b1), q(21, 'G9.2 Cheapest, no verifiedBy', b2), q(22, 'G9.3 Cheapest, verified', b3),
], null, 2));
fs.writeFileSync(`${dir}/prs.json`, '[]'); fs.writeFileSync(`${dir}/labels.json`, '{}');
fs.writeFileSync(`${dir}/comments.json`, '{}'); fs.writeFileSync(`${dir}/writes.log`, '');
JS

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
ci() { printf '%s' "$1" > "$TMP/gh/ci.json"; }
field() { # <json> <expr over r> -> printed value
  printf '%s' "$1" | node -e "const r=JSON.parse(require('fs').readFileSync(0,'utf8')); console.log($2)"
}
alarms() { field "$1" "r.alarms.filter(a=>a.code==='$2').map(a=>a.issue).sort().join(' ')"; }
launched() { field "$1" "r.launched.map(l=>l.issue).sort().join(' ')"; }
started() { ls "$TMP/claude-log" 2>/dev/null | sed -n 's/\.[0-9]*\.argv$//p' | sort | tr '\n' ' ' | sed 's/ $//'; }
pushed() { git --git-dir "$TMP/remote.git" for-each-ref --format='%(refname:short)' refs/heads | grep -v '^main$' | sort | tr '\n' ' ' | sed 's/ $//'; }

# --- 1. disabled CI: every package refused, nothing launches -----------------
ci '{"workflows":[{"name":"ci","state":"disabled_manually"}]}'
OUT=$(fleet cycle --apply --json 2>/dev/null); EXIT=$?
assert_eq 0 "$EXIT" "1: the applied cycle runs to completion"
assert_eq "20 22" "$(alarms "$OUT" launch-ci-disabled)" "1: the disabled-CI target refuses every package that passes the scope checks"
assert_eq "21" "$(alarms "$OUT" unlaunchable)" "1: the cheapest package with no verifiedBy is refused before the CI check"
assert_empty "$(launched "$OUT")" "1: the cycle reports nothing launched"
[ -d "$TMP/worktrees" ] && _fail "1: no worktree is created" "$(ls -R "$TMP/worktrees")" || _pass "1: no worktree is created"
# Read at once: every launch was refused before the spawn, so no detached stub
# exists to write here later.
assert_empty "$(started)" "1: no worker process was started"
assert_empty "$(pushed)" "1: no branch was pushed"

# --- 2. healthy CI: cheapest without verifiedBy is refused, the rest launch --
ci '{}'
OUT=$(fleet cycle --apply --json 2>/dev/null); EXIT=$?
assert_eq 0 "$EXIT" "2: the applied cycle runs to completion"
assert_eq "21" "$(alarms "$OUT" unlaunchable)" "2: the cheapest package with no verifiedBy is unlaunchable"
assert_contains "$(field "$OUT" "r.alarms.filter(a=>a.issue===21).map(a=>a.detail).join(' | ')")" "verifiedBy" "2: the refusal names verifiedBy"
assert_empty "$(alarms "$OUT" launch-ci-disabled)" "2: with CI enabled, no CI refusal is raised"
assert_eq "20 22" "$(launched "$OUT")" "2: the default-tier and the verified cheapest packages launch"
wait_for_count "$TMP/claude-log" '*.argv' 2
assert_eq "G9.1 G9.3" "$(started)" "2: workers started for exactly those two packages"
assert_not_contains "$(pushed)" "g9-2" "2: no branch was pushed for the refused package"

finish
