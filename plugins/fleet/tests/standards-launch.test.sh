#!/usr/bin/env bash
# Launch requires a valid standards manifest on the target's default branch
# (targets[].standards, default { "manifest": ".claude/standards.json" }), the
# same way it requires enabled CI. A missing, unreadable or defective manifest
# refuses the launch with its own stage; "off" launches and says so. The dry
# run and the report carry the check names and the rule counts, and the worker
# prompt names every check command and only the rules whose paths overlap the
# lane.
#
# Modeled on ci-preconditions.test.sh: most cases are dry runs, which go
# through the same launch() checks as applied cycles.
set -uo pipefail
cd "$(dirname "$0")"
. ./lib.sh

HERE=$(pwd -P)
FLEET="$(cd .. && pwd -P)/bin/fleet.js"
LAUNCH="$(cd .. && pwd -P)/src/launch.js"
PLUGIN="$(cd ../../agentic-work-packages && pwd -P)"
assert_file "$FLEET" "fleet.js exists"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
TMP=$(cd "$TMP" && pwd -P)

git init -q --bare -b main "$TMP/remote.git"
git clone -q "$TMP/remote.git" "$TMP/clone" 2>/dev/null
git -C "$TMP/clone" checkout -q -b main 2>/dev/null || true
git -C "$TMP/clone" config user.email f@example.invalid; git -C "$TMP/clone" config user.name fixture
mkdir -p "$TMP/clone/packages/web" "$TMP/clone/packages/api" "$TMP/clone/docs"
printf '# api\n' > "$TMP/clone/README.md"
printf 'web\n' > "$TMP/clone/packages/web/index.js"
printf 'api\n' > "$TMP/clone/packages/api/index.js"
printf '# web rules\n' > "$TMP/clone/docs/web.md"
printf '# api rules\n' > "$TMP/clone/docs/api.md"
printf '# all rules\n' > "$TMP/clone/docs/all.md"
# Project settings, so an isolated launch (isolateWorkers) is not refused
# hooks-missing, and case E's declared plugin is not refused plugin-missing.
mkdir -p "$TMP/clone/.claude"
printf '{"enabledPlugins": {"agentic-work-packages@example-market": true, "fleet@nodots": true}}\n' > "$TMP/clone/.claude/settings.json"
git -C "$TMP/clone" add -A && git -C "$TMP/clone" commit -qm init && git -C "$TMP/clone" push -q -u origin main

# publish <manifest-json>: commit it as .claude/standards.json on main and push.
publish() {
  mkdir -p "$TMP/clone/.claude"
  printf '%s\n' "$1" > "$TMP/clone/.claude/standards.json"
  git -C "$TMP/clone" add .claude/standards.json && git -C "$TMP/clone" commit -qm "standards" && git -C "$TMP/clone" push -q origin main
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
  + JSON.stringify({ feature: 'f', branch: 'feat/t1-1-web', allowedPaths: ['packages/web/**'], forbiddenPaths: [], dependsOn: [], execution: { model: 'default', pattern: 'solo' } })
  + '\n```\n';
fs.writeFileSync(`${dir}/issues.json`, JSON.stringify([
  { number: 1, title: 'Epic: program T', body: '', state: 'OPEN', labels: ['epic'] },
  { number: 10, title: 'T1.1 Web', body, state: 'OPEN', labels: ['agent-ready', 'cell:queued', 'worker:a'] },
], null, 2));
fs.writeFileSync(`${dir}/prs.json`, '[]'); fs.writeFileSync(`${dir}/labels.json`, '{}');
fs.writeFileSync(`${dir}/comments.json`, '{}'); fs.writeFileSync(`${dir}/writes.log`, '');
JS
printf '{}' > "$TMP/gh/ci.json"

write_config() { # target-extra-json-fields (may be empty) [defaultBranch]
  cat > "$TMP/fleet.config.json" <<JSON
{
  "repo": "acme/host", "epic": 1,
  "targets": [{ "repo": "acme/api", "localPath": "$TMP/clone", "defaultBranch": "${2:-main}" $1 }],
  "workers": { "a": { "mode": "local" } },
  "wipCap": 4, "worktreesDir": "$TMP/worktrees", "stateDir": "$TMP/state",
  "pluginRoot": "$PLUGIN", "noMovementLimit": 99
}
JSON
}
write_config ""
fleet() { node "$FLEET" "$@" --config "$TMP/fleet.config.json"; }

# alarms <json> <code> -> the issue numbers carrying that alarm code
alarms() { printf '%s' "$1" | node -e "const r=JSON.parse(require('fs').readFileSync(0,'utf8')); console.log(r.alarms.filter(a=>a.code===process.argv[1]).map(a=>a.issue).sort().join(' '))" "$2"; }
# launched <json> -> the issue numbers launched
launched() { printf '%s' "$1" | node -e "const r=JSON.parse(require('fs').readFileSync(0,'utf8')); console.log(r.launched.map(l=>l.issue).sort().join(' '))"; }
# detail <json> <code> -> the alarm detail text for that code
detail() { printf '%s' "$1" | node -e "const r=JSON.parse(require('fs').readFileSync(0,'utf8')); console.log(r.alarms.filter(a=>a.code===process.argv[1]).map(a=>a.detail).join(' | '))" "$2"; }
# standards <json> -> the launched row's standards record, as JSON
standards() { printf '%s' "$1" | node -e "const r=JSON.parse(require('fs').readFileSync(0,'utf8')); const l=r.launched.find(x=>x.issue===10); console.log(JSON.stringify(l ? l.standards : null))"; }

# --- A. no manifest on the default branch: standards-missing -----------------
OUT=$(fleet cycle --json 2>/dev/null)
assert_eq "10" "$(alarms "$OUT" launch-standards-missing)" "A: a target with no manifest is refused standards-missing"
assert_empty "$(launched "$OUT")" "A: nothing is launched"
assert_contains "$(detail "$OUT" launch-standards-missing)" ".claude/standards.json" "A: the alarm names the manifest path"
assert_contains "$(detail "$OUT" launch-standards-missing)" "origin/main" "A: the alarm names the branch it read"
OUT=$(fleet cycle --apply --json 2>/dev/null)
assert_eq "10" "$(alarms "$OUT" launch-standards-missing)" "A: the applied cycle refuses too"
[ -d "$TMP/worktrees" ] && _fail "A: no worktree is created for a refused launch" "worktrees dir exists" || _pass "A: no worktree is created for a refused launch"
# Read at once: the launch was refused before the spawn, so no detached stub
# exists to write here later.
assert_empty "$(ls "$TMP/claude-log")" "A: no worker was started"
assert_empty "$(git --git-dir "$TMP/remote.git" for-each-ref --format='%(refname:short)' refs/heads | grep '^feat/')" "A: no branch was pushed"

# --- B. standards "off": launched and reported as off -------------------------
write_config ', "standards": "off"'
OUT=$(fleet cycle --json 2>/dev/null)
assert_eq "10" "$(launched "$OUT")" "B: standards off launches with no manifest"
assert_eq '"off"' "$(standards "$OUT")" "B: the dry-run row records standards off"
TEXT=$(fleet cycle 2>/dev/null)
assert_contains "$TEXT" "on feat/t1-1-web · standards: off" "B: the report line says standards: off"
write_config ""

# --- C. an unreadable branch: standards-unreadable ----------------------------
write_config "" "gone"
OUT=$(fleet cycle --json 2>/dev/null)
assert_eq "10" "$(alarms "$OUT" launch-standards-unreadable)" "C: a default branch git cannot read is refused standards-unreadable"
assert_contains "$(detail "$OUT" launch-standards-unreadable)" "origin/gone" "C: the alarm names the ref"
assert_contains "$(detail "$OUT" launch-standards-unreadable)" "git" "C: the alarm says git failed"
write_config ""

# --- D. a defective manifest: standards-invalid, naming the defect ------------
publish '{"version": 1, "checks": [{"name": "test", "command": "npm test"}], "rules": [{"doc": "docs/nope.md", "paths": ["packages/web/**"], "check": "test"}]}'
OUT=$(fleet cycle --json 2>/dev/null)
assert_eq "10" "$(alarms "$OUT" launch-standards-invalid)" "D: a defective manifest is refused standards-invalid"
assert_empty "$(launched "$OUT")" "D: nothing is launched"
assert_contains "$(detail "$OUT" launch-standards-invalid)" 'rules[0].doc: "docs/nope.md" is not a tracked file' "D: the alarm lists the defect"

# --- E. a valid manifest: the dry run and the report carry it -----------------
VALID='{"version": 1,
 "checks": [{"name": "test", "command": "npm test"}, {"name": "lint", "command": "npm run lint -- --max-warnings 0"}],
 "rules": [
  {"doc": "docs/web.md", "paths": ["packages/web/**"], "check": "test"},
  {"doc": "docs/api.md", "paths": ["packages/api/**"], "check": "lint"},
  {"doc": "docs/all.md", "check": null}],
 "plugins": [{"name": "fleet", "marketplace": "nodots"}]}'
publish "$VALID"
OUT=$(fleet cycle --json 2>/dev/null)
assert_eq "10" "$(launched "$OUT")" "E: a valid manifest launches"
assert_empty "$(alarms "$OUT" launch-standards-invalid)" "E: no standards alarm"
assert_eq '{"checks":["test","lint"],"rules":3,"applicable":2}' "$(standards "$OUT")" "E: the dry-run row carries check names and rule counts"
TEXT=$(fleet cycle 2>/dev/null)
assert_contains "$TEXT" "on feat/t1-1-web · standards: test, lint (2 of 3 rules in lane)" "E: the report line carries the checks and the counts"
write_config ', "standards": { "manifest": ".claude/standards.json" }'
OUT=$(fleet cycle --json 2>/dev/null)
assert_eq "10" "$(launched "$OUT")" "E: the default, written out, launches the same"
write_config ""

# --- F. targets[].standards is validated --------------------------------------
for bad in '"on"' '5' 'null' '{}' '{ "manifest": "" }' '{ "manifest": "../x.json" }' '{ "manifest": "a/../x.json" }' '{ "manifest": "/etc/x.json" }' '{ "manifest": 3 }'; do
  write_config ", \"standards\": $bad"
  OUT=$(fleet cycle --json 2>&1); EXIT=$?
  assert_ne 0 "$EXIT" "F: standards $bad is a config error"
  assert_contains "$OUT" "targets[0].standards" "F: the error for $bad names the field"
done
write_config ""

# --- G. the applied prompt names the checks and only the lane's rules ---------
OUT=$(fleet cycle --apply --json 2>/dev/null)
assert_eq "10" "$(launched "$OUT")" "G: the applied cycle launches"
assert_eq '{"checks":["test","lint"],"rules":3,"applicable":2}' "$(standards "$OUT")" "G: the applied row carries the standards record"
wait_for_file "$TMP/claude-log/T1.1.*.argv"
ARGV=$(cat "$TMP"/claude-log/T1.1.*.argv 2>/dev/null)
assert_contains "$ARGV" "Standards for acme/api are in .claude/standards.json in this worktree. Before you claim [READY]: T1.1, run every check in order and quote each command with its summary in the VERIFIED stamp:" "G: the prompt points at the manifest"
assert_contains "$ARGV" "test: npm test" "G: the prompt names the test command"
assert_contains "$ARGV" "lint: npm run lint -- --max-warnings 0" "G: the prompt names the lint command"
assert_contains "$ARGV" "Rules for your lane; read each doc before changing code under its paths:" "G: the prompt lists the lane's rules"
assert_contains "$ARGV" "docs/web.md (packages/web/**)" "G: the rule scoped to packages/web/** is named"
assert_contains "$ARGV" "docs/all.md (all paths)" "G: the rule with no paths is named"
assert_not_contains "$ARGV" "docs/api.md" "G: the rule scoped to packages/api/** is not"
assert_contains "$ARGV" "This repo's standards expect fleet@nodots; if a skill or hook from it is absent in this session, say so in HANDOFF.md." "G: the plugins line"
STATE=$(cat "$TMP"/state/*.json 2>/dev/null)
assert_contains "$STATE" '"applicable": 2' "G: the session record carries the standards record"

# --- H. prompt lines with no applicable rule and no plugins -------------------
NOPE=$(node - "$LAUNCH" <<'JS'
const { buildPrompt } = require(process.argv[2]);
const p = buildPrompt({ repo: 'acme/host', contractPath: '/c.md' }, {
  issue: { number: 10 }, id: 'T1.1', sc: { branch: 'feat/x', allowedPaths: ['tools/**'], execution: { pattern: 'solo' } },
  workerId: 'a', target: { repo: 'acme/api', defaultBranch: 'main', ci: { gate: 'github-actions' }, standards: { manifest: '.claude/standards.json' } },
  attempt: 1, worktree: null,
  standards: { manifest: { checks: [{ name: 'test', command: 'npm test' }], rules: [{ doc: 'docs/web.md', paths: ['packages/web/**'], check: 'test' }], plugins: [] } },
});
console.log(p);
JS
)
assert_contains "$NOPE" "No rule in .claude/standards.json names paths in your lane; the checks still apply." "H: a lane no rule overlaps is told so"
assert_contains "$NOPE" "test: npm test" "H: and still gets the checks"
assert_not_contains "$NOPE" "standards expect" "H: no plugins line when plugins is empty"
OFFP=$(node - "$LAUNCH" <<'JS'
const { buildPrompt } = require(process.argv[2]);
console.log(buildPrompt({ repo: 'acme/host', contractPath: '/c.md' }, {
  issue: { number: 10 }, id: 'T1.1', sc: { branch: 'feat/x', allowedPaths: ['tools/**'], execution: { pattern: 'solo' } },
  workerId: 'a', target: { repo: 'acme/api', defaultBranch: 'main', ci: { gate: 'github-actions' }, standards: 'off' }, attempt: 1, worktree: null,
}));
JS
)
assert_not_contains "$OFFP" "Standards for" "H: standards off adds no standards lines"

# --- I. the prefix rule, case by case -----------------------------------------
# pathsOverlap(rulePath, lanePath): the literal prefixes (text before the first
# *, ?, [ or {, trailing / trimmed) overlap when one is a prefix of the other.
overlap() { node -e "const { pathsOverlap } = require(process.argv[1]); console.log(String(pathsOverlap(process.argv[2], process.argv[3])))" "$LAUNCH" "$1" "$2" 2>&1; }
while IFS='|' read -r a b want; do
  [ -z "$a" ] && continue
  assert_eq "$want" "$(overlap "$a" "$b")" "I: pathsOverlap($a, $b) is $want"
done <<'CASES'
packages/web/**|packages/web/**|true
packages/web/**|packages/web/src/a.js|true
packages/**|packages/web/**|true
packages/web/**|packages/**|true
packages/web/**|packages/api/**|false
packages/api/**|packages/web/**|false
**/*.md|packages/web/**|true
packages/web/**|**|true
src/*.js|src/**|true
docs/|docs/**|true
packages/{web,api}/**|packages/web/**|true
lib/a?.js|lib/b.js|false
lib/[ab].js|lib/c.js|true
packages/webapp/**|packages/web/**|true
README.md|src/**|false
src/a.js|src/a.js|true
src/a.js|src/b.js|false
CASES

finish
