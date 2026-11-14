#!/usr/bin/env bash
# Launch preconditions for unattended workers: the target repo must have an
# enabled CI workflow and a workflow run on its default branch inside
# ciMaxAgeDays, and a package on the cheapest model tier must name the check
# that verifies its output (execution.verifiedBy).
#
# Dry runs go through the same launch() checks as applied cycles, so most cases
# are dry runs; one applied cycle proves a refusal creates no worktree and
# starts no worker.
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

STUB="$TMP/stub"; mkdir -p "$STUB" "$TMP/gh" "$TMP/claude-log"
cp "$HERE/stubs/gh.js" "$STUB/gh.js"
printf '#!/usr/bin/env bash\nexec node "%s/gh.js" "$@"\n' "$STUB" > "$STUB/gh"; chmod +x "$STUB/gh"
cp "$HERE/stubs/claude.sh" "$STUB/claude"; chmod +x "$STUB/claude"
export GH_STUB_DIR="$TMP/gh" GH_STUB_REMOTE="$TMP/remote.git" CLAUDE_STUB_LOG="$TMP/claude-log" CLAUDE_STUB_TARGET="acme/api"
export GH_BIN="$STUB/gh" CLAUDE_BIN="$STUB/claude"
export CLAUDE_CONFIG_FILE="$TMP/claude.json"
node -e "require('fs').writeFileSync('$TMP/claude.json', JSON.stringify({projects:{['$TMP/clone']:{hasTrustDialogAccepted:true}}}))"
unset CLAUDECODE

scope_body() { # branch execution-json
  printf '**Part of** #1 · **Phase 1 · x** · **Repo:** `acme/api`\n\n## Goal\nx\n\n### SCOPE.json\n```json\n{"feature":"f","branch":"%s","allowedPaths":["src/**"],"forbiddenPaths":["contracts/**"],"dependsOn":[],"execution":%s}\n```\n' "$1" "$2"
}
node - "$TMP/gh" \
  "$(scope_body feat/t1-1-plain '{"model":"default","pattern":"solo"}')" \
  "$(scope_body feat/t1-2-cheap-bare '{"model":"cheapest","pattern":"solo"}')" \
  "$(scope_body feat/t1-3-cheap-verified '{"model":"cheapest","pattern":"solo","verifiedBy":"fleet tests/*.test.sh"}')" \
  "$(scope_body feat/t1-4-cheap-empty '{"model":"cheapest","pattern":"solo","verifiedBy":""}')" <<'JS'
const fs = require('fs'); const [dir, b1, b2, b3, b4] = process.argv.slice(2);
const q = (number, title, body) => ({ number, title, body, state: 'OPEN', labels: ['agent-ready', 'cell:queued', 'worker:a'] });
fs.writeFileSync(`${dir}/issues.json`, JSON.stringify([
  { number: 1, title: 'Epic: program T', body: '', state: 'OPEN', labels: ['epic'] },
  q(10, 'T1.1 Plain', b1), q(11, 'T1.2 Cheap, no check', b2), q(12, 'T1.3 Cheap, verified', b3), q(13, 'T1.4 Cheap, empty check', b4),
], null, 2));
fs.writeFileSync(`${dir}/prs.json`, '[]'); fs.writeFileSync(`${dir}/labels.json`, '{}');
fs.writeFileSync(`${dir}/comments.json`, '{}'); fs.writeFileSync(`${dir}/writes.log`, '');
JS

write_config() { # extra-json-fields (may be empty)
  cat > "$TMP/fleet.config.json" <<JSON
{
  "repo": "acme/host", "epic": 1,
  "targets": [{ "repo": "acme/api", "localPath": "$TMP/clone", "defaultBranch": "main" }],
  "workers": { "a": { "mode": "local" } },
  "wipCap": 4, "worktreesDir": "$TMP/worktrees", "stateDir": "$TMP/state",
  "pluginRoot": "$PLUGIN", "noMovementLimit": 99
  $1
}
JSON
}
write_config ""
fleet() { node "$FLEET" "$@" --config "$TMP/fleet.config.json"; }
ci() { printf '%s' "$1" > "$TMP/gh/ci.json"; }
days_ago() { node -e "console.log(new Date(Date.now() - $1 * 86400000).toISOString())"; }

# alarms <json> <code> -> the issue numbers carrying that alarm code, space separated
alarms() { printf '%s' "$1" | node -e "const r=JSON.parse(require('fs').readFileSync(0,'utf8')); console.log(r.alarms.filter(a=>a.code===process.argv[1]).map(a=>a.issue).sort().join(' '))" "$2"; }
# launched <json> -> the issue numbers launched, space separated
launched() { printf '%s' "$1" | node -e "const r=JSON.parse(require('fs').readFileSync(0,'utf8')); console.log(r.launched.map(l=>l.issue).sort().join(' '))"; }
# detail <json> <code> -> the alarm detail text for that code
detail() { printf '%s' "$1" | node -e "const r=JSON.parse(require('fs').readFileSync(0,'utf8')); console.log(r.alarms.filter(a=>a.code===process.argv[1]).map(a=>a.detail).join(' | '))" "$2"; }

# --- A. healthy CI: plain and verified packages launch as before ---------------
ci '{}'
OUT=$(fleet cycle --json 2>/dev/null)
assert_contains "$(launched "$OUT")" "10" "A: a default-tier package launches when CI is enabled and recent"
assert_contains "$(launched "$OUT")" "12" "A: a cheapest package with verifiedBy launches"

# --- B. a package on the cheapest tier needs execution.verifiedBy -------------
assert_eq "11 13" "$(alarms "$OUT" unlaunchable)" "B: cheapest with no verifiedBy, or an empty one, is unlaunchable"
assert_contains "$(detail "$OUT" unlaunchable)" "verifiedBy" "B: the alarm names the missing field"
assert_not_contains "$(launched "$OUT")" "11" "B: the package with no verifiedBy is not launched"
assert_not_contains "$(launched "$OUT")" "13" "B: the package with an empty verifiedBy is not launched"

# --- C. no enabled workflow: refused with a named alarm, nothing launched -----
ci '{"workflows":[{"name":"ci","state":"disabled_manually"}]}'
OUT=$(fleet cycle --json 2>/dev/null)
assert_eq "10 12" "$(alarms "$OUT" launch-ci-disabled)" "C: a target whose only workflow is disabled is refused, per package"
assert_empty "$(launched "$OUT")" "C: nothing is launched into a target with disabled CI"
assert_contains "$(detail "$OUT" launch-ci-disabled)" "acme/api" "C: the alarm names the target repo"
ci '{"workflows":[]}'
OUT=$(fleet cycle --json 2>/dev/null)
assert_eq "10 12" "$(alarms "$OUT" launch-ci-disabled)" "C: a target with no workflow at all is refused the same way"

# --- D. no recent default-branch run: refused ---------------------------------
ci "{\"runs\":[{\"created_at\":\"$(days_ago 30)\"}]}"
OUT=$(fleet cycle --json 2>/dev/null)
assert_eq "10 12" "$(alarms "$OUT" launch-ci-stale)" "D: a last run older than ciMaxAgeDays (default 14) is refused"
assert_empty "$(launched "$OUT")" "D: nothing is launched when the last run is stale"
assert_contains "$(detail "$OUT" launch-ci-stale)" "14" "D: the alarm states the configured window"
ci '{"runs":[]}'
OUT=$(fleet cycle --json 2>/dev/null)
assert_eq "10 12" "$(alarms "$OUT" launch-ci-stale)" "D: a default branch with no run at all is refused"
ci "{\"runs\":[{\"created_at\":\"$(days_ago 10)\"}]}"
OUT=$(fleet cycle --json 2>/dev/null)
assert_contains "$(launched "$OUT")" "10" "D: a run 10 days old is inside the default window"
write_config ', "ciMaxAgeDays": 5'
OUT=$(fleet cycle --json 2>/dev/null)
assert_eq "10 12" "$(alarms "$OUT" launch-ci-stale)" "D: the same 10-day-old run is stale under ciMaxAgeDays 5"
write_config ""

# --- E. an unreadable CI state is refused, not assumed healthy ----------------
ci '{"fail":true}'
OUT=$(fleet cycle --json 2>/dev/null)
assert_eq "10 12" "$(alarms "$OUT" launch-ci-check-failed)" "E: a failed CI query refuses the launch"
assert_empty "$(launched "$OUT")" "E: nothing is launched when CI cannot be read"

# --- F. an applied refusal creates no worktree and starts no worker -----------
ci '{"workflows":[]}'
OUT=$(fleet cycle --apply --json 2>/dev/null)
assert_eq "10 12" "$(alarms "$OUT" launch-ci-disabled)" "F: the applied cycle refuses too"
[ -d "$TMP/worktrees" ] && _fail "F: no worktree is created for a refused launch" "worktrees dir exists" || _pass "F: no worktree is created for a refused launch"
assert_empty "$(ls "$TMP/claude-log")" "F: no worker was started"
assert_empty "$(git --git-dir "$TMP/remote.git" for-each-ref --format='%(refname:short)' refs/heads | grep '^feat/')" "F: no branch was pushed"

# --- G. ciMaxAgeDays is validated ---------------------------------------------
write_config ', "ciMaxAgeDays": 0'
OUT=$(fleet cycle --json 2>&1); EXIT=$?
assert_ne 0 "$EXIT" "G: ciMaxAgeDays 0 is a config error"
assert_contains "$OUT" "ciMaxAgeDays" "G: the error names the field"

# --- H. a target verified outside GitHub Actions: ci.gate "external" ---------
write_external() { # ci-json
  cat > "$TMP/fleet.config.json" <<JSON
{
  "repo": "acme/host", "epic": 1,
  "targets": [{ "repo": "acme/api", "localPath": "$TMP/clone", "defaultBranch": "main", "ci": $1 }],
  "workers": { "a": { "mode": "local" } },
  "wipCap": 4, "worktreesDir": "$TMP/worktrees-h", "stateDir": "$TMP/state-h",
  "pluginRoot": "$PLUGIN", "noMovementLimit": 99
}
JSON
}
ci '{"workflows":[]}'
write_external '{"gate":"external","verifiedBy":"npm run test:impacted on the lab, under the lab lock"}'
OUT=$(fleet cycle --json 2>/dev/null)
assert_empty "$(alarms "$OUT" launch-ci-disabled)" "H: an external target is not refused for having no workflow"
assert_empty "$(alarms "$OUT" launch-ci-stale)" "H: nor for having no recent run"
assert_contains "$(launched "$OUT")" "10" "H: a default-tier package launches into an external target"
assert_eq "11 13" "$(alarms "$OUT" unlaunchable)" "H: the verifiedBy rule for the cheapest tier still applies"
GATE=$(printf '%s' "$OUT" | node -e "const r=JSON.parse(require('fs').readFileSync(0,'utf8')); const l=r.launched.find(x=>x.issue===10); console.log(l.ci.gate+' | '+l.ci.verifiedBy)")
assert_eq "external | npm run test:impacted on the lab, under the lab lock" "$GATE" "H: the dry run records the gate and what verifies the work"
ci '{"fail":true}'
OUT=$(fleet cycle --json 2>/dev/null)
assert_empty "$(alarms "$OUT" launch-ci-check-failed)" "H: the GitHub Actions state is not read for an external target"
ci '{"workflows":[]}'
OUT=$(fleet cycle --apply --json 2>/dev/null)
assert_contains "$(launched "$OUT")" "10" "H: the applied cycle launches into the external target"
ARGV=$(cat "$TMP"/claude-log/T1.1.*.argv 2>/dev/null)
assert_contains "$ARGV" "Verification for this target: npm run test:impacted on the lab, under the lab lock" "H: the worker is told what verifies its work"
assert_contains "$ARGV" "not from a pipeline" "H: and that its VERIFIED stamp comes from that run"

write_external '{"gate":"external"}'
OUT=$(fleet cycle --json 2>&1); EXIT=$?
assert_ne 0 "$EXIT" "H: ci.gate external with no verifiedBy is a config error"
assert_contains "$OUT" "ci.verifiedBy" "H: the error names the missing field"
write_external '{"gate":"external","verifiedBy":"   "}'
OUT=$(fleet cycle --json 2>&1); EXIT=$?
assert_ne 0 "$EXIT" "H: a blank verifiedBy is refused the same way"
write_external '{"gate":"jenkins"}'
OUT=$(fleet cycle --json 2>&1); EXIT=$?
assert_ne 0 "$EXIT" "H: an unknown gate is a config error"
assert_contains "$OUT" "github-actions, external" "H: the error lists the gates"
write_external '{"gate":"github-actions"}'
OUT=$(fleet cycle --json 2>/dev/null)
assert_eq "10 12" "$(alarms "$OUT" launch-ci-disabled)" "H: an explicit github-actions gate checks CI as the default does"

finish
