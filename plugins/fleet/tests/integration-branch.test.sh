#!/usr/bin/env bash
# targets[].integrationBranch: a target that names one has each worker branch
# cut from origin/<integrationBranch>, its standards manifest and project
# settings read from that ref, and its worker told to open the PR against it.
# A missing integration branch refuses the launch integration-branch-missing,
# naming the push that creates it. A protected name, or autoMerge without an
# integration branch, is a config error naming the key. A target without the
# key reads origin/<defaultBranch> as before.
#
# Fixture: main carries no manifest and no settings, so a launch that reads
# main is refused standards-missing; integ carries both, so a launch that
# reads integ gets through.
set -uo pipefail
cd "$(dirname "$0")"
. ./lib.sh

HERE=$(pwd -P)
FLEET="$(cd .. && pwd -P)/bin/fleet.js"
CONFIG="$(cd .. && pwd -P)/src/config.js"
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
printf '# api\n' > "$TMP/clone/README.md"
git -C "$TMP/clone" add -A && git -C "$TMP/clone" commit -qm init && git -C "$TMP/clone" push -q -u origin main

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

write_config() { # target-extra-json-fields (may be empty) [top-level-extra-json-fields]
  cat > "$TMP/fleet.config.json" <<JSON
{
  "repo": "acme/host", "epic": 1,
  "targets": [{ "repo": "acme/api", "localPath": "$TMP/clone", "defaultBranch": "main" $1 }],
  "workers": { "a": { "mode": "local" } },
  "wipCap": 4, "worktreesDir": "$TMP/worktrees", "stateDir": "$TMP/state",
  "pluginRoot": "$PLUGIN", "noMovementLimit": 99 ${2:-}
}
JSON
}
fleet() { node "$FLEET" "$@" --config "$TMP/fleet.config.json"; }

alarms() { printf '%s' "$1" | node -e "const r=JSON.parse(require('fs').readFileSync(0,'utf8')); console.log(r.alarms.filter(a=>a.code===process.argv[1]).map(a=>a.issue).sort().join(' '))" "$2"; }
launched() { printf '%s' "$1" | node -e "const r=JSON.parse(require('fs').readFileSync(0,'utf8')); console.log(r.launched.map(l=>l.issue).sort().join(' '))"; }
detail() { printf '%s' "$1" | node -e "const r=JSON.parse(require('fs').readFileSync(0,'utf8')); console.log(r.alarms.filter(a=>a.code===process.argv[1]).map(a=>a.detail).join(' | '))" "$2"; }

# --- A. validation: protected names, autoMerge alone, the protected list -------
for bad in main master develop development; do
  write_config ", \"integrationBranch\": \"$bad\""
  OUT=$(fleet cycle --json 2>&1); EXIT=$?
  assert_ne 0 "$EXIT" "A: integrationBranch $bad is a config error"
  assert_contains "$OUT" "targets[0].integrationBranch" "A: the error for $bad names the key"
done
cat > "$TMP/fleet.config.json" <<JSON
{ "repo": "acme/host", "epic": 1,
  "targets": [{ "repo": "acme/api", "localPath": "$TMP/clone", "defaultBranch": "trunk", "integrationBranch": "trunk" }],
  "workers": { "a": { "mode": "local" } }, "worktreesDir": "$TMP/worktrees", "stateDir": "$TMP/state", "pluginRoot": "$PLUGIN" }
JSON
OUT=$(fleet cycle --json 2>&1); EXIT=$?
assert_ne 0 "$EXIT" "A: integrationBranch equal to the target's defaultBranch is a config error"
assert_contains "$OUT" "targets[0].integrationBranch" "A: that error names the key"
write_config ', "integrationBranch": "release"' ', "protectedBranches": ["release"]'
OUT=$(fleet cycle --json 2>&1); EXIT=$?
assert_ne 0 "$EXIT" "A: integrationBranch in protectedBranches is a config error"
assert_contains "$OUT" "targets[0].integrationBranch" "A: that error names the key"
write_config ', "autoMerge": true'
OUT=$(fleet cycle --json 2>&1); EXIT=$?
assert_ne 0 "$EXIT" "A: autoMerge without integrationBranch is a config error"
assert_contains "$OUT" "targets[0].autoMerge" "A: that error names the key"
write_config ', "integrationBranch": "integ", "autoMerge": "yes"'
OUT=$(fleet cycle --json 2>&1); EXIT=$?
assert_ne 0 "$EXIT" "A: a non-boolean autoMerge is a config error"
assert_contains "$OUT" "targets[0].autoMerge" "A: that error names the key"
for bad in '""' '5' '"-x"' '"a..b"' '"a b"'; do
  write_config ", \"integrationBranch\": $bad"
  OUT=$(fleet cycle --json 2>&1); EXIT=$?
  assert_ne 0 "$EXIT" "A: integrationBranch $bad is a config error"
  assert_contains "$OUT" "targets[0].integrationBranch" "A: the error for $bad names the key"
done
for bad in '"release"' '[3]' '[""]'; do
  write_config "" ", \"protectedBranches\": $bad"
  OUT=$(fleet cycle --json 2>&1); EXIT=$?
  assert_ne 0 "$EXIT" "A: protectedBranches $bad is a config error"
  assert_contains "$OUT" "protectedBranches" "A: the error for $bad names the key"
done
PROT=$(node - "$CONFIG" <<'JS'
const { validate, isProtected } = require(process.argv[2]);
const cfg = validate({ repo: 'acme/host', epic: 1, targets: [{ repo: 'acme/api', localPath: '/x', defaultBranch: 'trunk', integrationBranch: 'integ', autoMerge: true }],
  workers: { a: { mode: 'local' } }, worktreesDir: '/w', pluginRoot: '/p', protectedBranches: ['release'] }, '/');
const t = cfg.targets[0];
console.log([isProtected(cfg, t, 'main'), isProtected(cfg, t, 'development'), isProtected(cfg, t, 'trunk'), isProtected(cfg, t, 'release'), isProtected(cfg, t, 'integ'), t.integrationBranch, t.autoMerge].join(' '));
const bare = validate({ repo: 'acme/host', epic: 1, targets: [{ repo: 'acme/api', localPath: '/x' }], workers: { a: { mode: 'local' } }, worktreesDir: '/w', pluginRoot: '/p' }, '/');
console.log([bare.targets[0].integrationBranch, bare.targets[0].autoMerge, JSON.stringify(bare.protectedBranches), isProtected(bare, bare.targets[0], 'release')].join(' '));
JS
)
assert_eq "true true true true false integ true
 false [] false" "$PROT" "A: isProtected covers the built-in names, defaultBranch and protectedBranches; the keys default absent, false and []"

# --- B. without the key: origin/main is read, as before ------------------------
write_config ""
OUT=$(fleet cycle --json 2>/dev/null)
assert_eq "10" "$(alarms "$OUT" launch-standards-missing)" "B: a target without the key reads main, which has no manifest"
assert_contains "$(detail "$OUT" launch-standards-missing)" "origin/main" "B: the alarm names origin/main"
assert_empty "$(alarms "$OUT" launch-integration-branch-missing)" "B: no integration-branch alarm without the key"

# --- C. the key names a branch origin does not have: refused -------------------
write_config ', "integrationBranch": "integ"'
OUT=$(fleet cycle --json 2>/dev/null)
assert_eq "10" "$(alarms "$OUT" launch-integration-branch-missing)" "C: a missing integration branch is refused integration-branch-missing"
assert_empty "$(launched "$OUT")" "C: nothing is launched"
assert_contains "$(detail "$OUT" launch-integration-branch-missing)" "origin/integ" "C: the alarm names the branch"
assert_contains "$(detail "$OUT" launch-integration-branch-missing)" "git push origin main:integ" "C: the alarm names the push that creates it"
OUT=$(fleet cycle --apply --json 2>/dev/null)
assert_eq "10" "$(alarms "$OUT" launch-integration-branch-missing)" "C: the applied cycle refuses too"
[ -d "$TMP/worktrees" ] && _fail "C: no worktree is created for a refused launch" "worktrees dir exists" || _pass "C: no worktree is created for a refused launch"
assert_empty "$(ls "$TMP/claude-log")" "C: no worker was started"

# --- D. integ has the manifest but no settings: the settings read is integ's ---
git -C "$TMP/clone" checkout -q -b integ
mkdir -p "$TMP/clone/.claude"
printf '{"version": 1, "checks": [{"name": "test", "command": "true"}], "rules": []}\n' > "$TMP/clone/.claude/standards.json"
git -C "$TMP/clone" add .claude/standards.json && git -C "$TMP/clone" commit -qm "integ: standards" && git -C "$TMP/clone" push -q -u origin integ
OUT=$(fleet cycle --json 2>/dev/null)
assert_empty "$(alarms "$OUT" launch-standards-missing)" "D: the manifest is read from integ"
assert_eq "10" "$(alarms "$OUT" launch-hooks-missing)" "D: integ has no settings, so hooks-missing"
assert_contains "$(detail "$OUT" launch-hooks-missing)" "origin/integ" "D: the settings read names origin/integ"

# --- E. integ has both: the worktree, the prompt and the doctor use it ---------
printf '{"enabledPlugins": {"agentic-work-packages@example-market": true}}\n' > "$TMP/clone/.claude/settings.json"
git -C "$TMP/clone" add .claude/settings.json && git -C "$TMP/clone" commit -qm "integ: settings" && git -C "$TMP/clone" push -q origin integ
git -C "$TMP/clone" checkout -q main
INTEG_SHA=$(git -C "$TMP/clone" rev-parse origin/integ)
OUT=$(fleet cycle --json 2>/dev/null)
assert_eq "10" "$(launched "$OUT")" "E: the dry run launches from integ"
OUT=$(fleet cycle --apply --json 2>/dev/null)
assert_eq "10" "$(launched "$OUT")" "E: the applied cycle launches"
WT=$(ls -d "$TMP"/worktrees/*/ 2>/dev/null | head -1)
assert_nonempty "$WT" "E: a worktree exists"
assert_eq "$INTEG_SHA" "$(git -C "$WT" rev-parse HEAD~1 2>/dev/null)" "E: the worktree starts from origin/integ"
ARGV=$(cat "$TMP"/claude-log/T1.1.*.argv 2>/dev/null)
assert_contains "$ARGV" "Open the PR against integ with a title" "E: the prompt names integ as the PR base"
assert_not_contains "$ARGV" "Open the PR against main" "E: and not main"
DOC=$(fleet doctor 2>&1)
assert_contains "$DOC" "base ref acme/api: origin/integ" "E: doctor prints the target's base ref"
assert_contains "$DOC" "ok    base ref acme/api: origin/integ" "E: and that it exists"
write_config ', "integrationBranch": "later"'
DOC=$(fleet doctor 2>&1)
assert_contains "$DOC" "FAIL  base ref acme/api: origin/later" "E: doctor fails a missing base ref"
assert_contains "$DOC" "git push origin main:later" "E: and names the push that creates it"
write_config ""
DOC=$(fleet doctor 2>&1)
assert_contains "$DOC" "ok    base ref acme/api: origin/main" "E: without the key the base ref is origin/main"

# --- F. without the key, the prompt's PR base is the default branch ------------
P=$(node - "$LAUNCH" <<'JS'
const { buildPrompt, baseRef } = require(process.argv[2]);
const mk = extra => ({ repo: 'acme/api', defaultBranch: 'main', ci: { gate: 'github-actions' }, standards: 'off', ...extra });
const args = target => ({ issue: { number: 10 }, id: 'T1.1', sc: { branch: 'feat/x', allowedPaths: [], execution: { pattern: 'solo' } }, workerId: 'a', target, attempt: 1, worktree: null });
const cfg = { repo: 'acme/host', contractPath: '/c.md' };
console.log(baseRef(mk({})), baseRef(mk({ integrationBranch: 'integ' })));
console.log(buildPrompt(cfg, args(mk({}))).includes('Open the PR against main with'));
JS
)
assert_eq "origin/main origin/integ
true" "$P" "F: baseRef is origin/<defaultBranch> without the key; the prompt says main"

finish
