#!/usr/bin/env bash
# targets[].verify: a target whose verifier admits one run at a time. The field
# is validated (loopback url, suite id, known kind, ci.gate external), and a
# worker on such a target is told to stop at a "[VERIFY]:" PR instead of running
# the verifier and opening "[READY]:". A target without verify is unchanged.
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

for name in api web; do
  git init -q --bare -b main "$TMP/$name.git"
  git clone -q "$TMP/$name.git" "$TMP/$name" 2>/dev/null
  git -C "$TMP/$name" checkout -q -b main 2>/dev/null || true
  git -C "$TMP/$name" config user.email f@example.invalid; git -C "$TMP/$name" config user.name fixture
  printf '# %s\n' "$name" > "$TMP/$name/README.md"
  git -C "$TMP/$name" add -A && git -C "$TMP/$name" commit -qm init && git -C "$TMP/$name" push -q -u origin main
done

STUB="$TMP/stub"; mkdir -p "$STUB" "$TMP/gh" "$TMP/claude-log"
cp "$HERE/stubs/gh.js" "$STUB/gh.js"
printf '#!/usr/bin/env bash\nexec node "%s/gh.js" "$@"\n' "$STUB" > "$STUB/gh"; chmod +x "$STUB/gh"
cp "$HERE/stubs/claude.sh" "$STUB/claude"; chmod +x "$STUB/claude"
export GH_STUB_DIR="$TMP/gh" GH_STUB_REMOTE="$TMP/api.git" CLAUDE_STUB_LOG="$TMP/claude-log" CLAUDE_STUB_TARGET="acme/api"
export GH_BIN="$STUB/gh" CLAUDE_BIN="$STUB/claude"
export CLAUDE_CONFIG_FILE="$TMP/claude.json"
node -e "require('fs').writeFileSync('$TMP/claude.json', JSON.stringify({projects:{['$TMP/api']:{hasTrustDialogAccepted:true},['$TMP/web']:{hasTrustDialogAccepted:true}}}))"
unset CLAUDECODE

scope_body() { # repo branch
  printf '**Part of** #1 · **Phase 1 · x** · **Repo:** `%s`\n\n## Goal\nx\n\n### SCOPE.json\n```json\n{"feature":"f","branch":"%s","allowedPaths":["src/**"],"forbiddenPaths":[],"dependsOn":[],"execution":{"model":"default","pattern":"solo"}}\n```\n' "$1" "$2"
}
node - "$TMP/gh" "$(scope_body acme/api feat/v1-1-on-lab)" "$(scope_body acme/web feat/v1-2-on-actions)" <<'JS'
const fs = require('fs'); const [dir, b1, b2] = process.argv.slice(2);
const q = (number, title, body) => ({ number, title, body, state: 'OPEN', labels: ['agent-ready', 'cell:queued', 'worker:a'] });
fs.writeFileSync(`${dir}/issues.json`, JSON.stringify([
  { number: 1, title: 'Epic: program V', body: '', state: 'OPEN', labels: ['epic'] },
  q(10, 'V1.1 On the lab', b1), q(11, 'V1.2 On Actions', b2),
], null, 2));
fs.writeFileSync(`${dir}/prs.json`, '[]'); fs.writeFileSync(`${dir}/labels.json`, '{}');
fs.writeFileSync(`${dir}/comments.json`, '{}'); fs.writeFileSync(`${dir}/writes.log`, '');
JS
printf '{}' > "$TMP/gh/ci.json"

EXT='{"gate":"external","verifiedBy":"npm run test:impacted -- --list prints the selection"}'
write_config() { # api-ci-json api-verify-json(or empty)
  local verify=""; [ -n "$2" ] && verify=", \"verify\": $2"
  cat > "$TMP/fleet.config.json" <<JSON
{
  "repo": "acme/host", "epic": 1,
  "targets": [
    { "repo": "acme/api", "localPath": "$TMP/api", "defaultBranch": "main", "ci": $1 $verify },
    { "repo": "acme/web", "localPath": "$TMP/web", "defaultBranch": "main" }
  ],
  "workers": { "a": { "mode": "local" } },
  "wipCap": 4, "worktreesDir": "$TMP/worktrees", "stateDir": "$TMP/state",
  "pluginRoot": "$PLUGIN", "noMovementLimit": 99
}
JSON
}
fleet() { node "$FLEET" "$@" --config "$TMP/fleet.config.json"; }
refused() { # label verify-json needle [ci-json]
  write_config "${4:-$EXT}" "$2"
  local out; out=$(fleet cycle --json 2>&1); local code=$?
  assert_ne 0 "$code" "$1: is a config error"
  assert_contains "$out" "$3" "$1: the error says [$3]"
}
GOOD='{"kind":"lab-runner","url":"http://127.0.0.1:7357","suite":"impacted_v2"}'

# --- A. each validation refusal ----------------------------------------------
refused "A: a non-loopback url"   '{"kind":"lab-runner","url":"http://10.0.0.5:7357","suite":"s"}' "loopback"
refused "A: a public hostname"    '{"kind":"lab-runner","url":"http://lab.example.com:7357","suite":"s"}' "loopback"
refused "A: a url that is not one" '{"kind":"lab-runner","url":"not a url","suite":"s"}' "verify.url"
refused "A: a bad suite id"       '{"kind":"lab-runner","url":"http://127.0.0.1:7357","suite":"a b;rm"}' "verify.suite"
refused "A: an empty suite id"    '{"kind":"lab-runner","url":"http://127.0.0.1:7357","suite":""}' "verify.suite"
refused "A: an unknown kind"      '{"kind":"jenkins","url":"http://127.0.0.1:7357","suite":"s"}' "verify.kind"
refused "A: verify without ci.gate external" "$GOOD" "ci.gate external" '{"gate":"github-actions"}'
refused "A: verify that is not an object" '"lab"' "verify"

# --- B. valid forms load ------------------------------------------------------
for url in "http://127.0.0.1:7357" "http://localhost:7357" "http://[::1]:7357" "http://127.0.0.2:80"; do
  write_config "$EXT" "{\"kind\":\"lab-runner\",\"url\":\"$url\",\"suite\":\"s-1\"}"
  OUT=$(fleet cycle --json 2>&1); CODE=$?
  assert_eq 0 "$CODE" "B: loopback url $url is accepted"
done

# --- C. the applied cycle: the verify target's worker stops at [VERIFY] ------
write_config "$EXT" "$GOOD"
OUT=$(fleet cycle --apply --json 2>/dev/null)
LAUNCHED=$(printf '%s' "$OUT" | node -e "const r=JSON.parse(require('fs').readFileSync(0,'utf8')); console.log(r.launched.map(l=>l.issue).sort().join(' '))")
assert_eq "10 11" "$LAUNCHED" "C: both packages launch"
LAB=$(cat "$TMP"/claude-log/V1.1.*.argv 2>/dev/null)
ACT=$(cat "$TMP"/claude-log/V1.2.*.argv 2>/dev/null)
assert_nonempty "$LAB" "C: the verify target's worker was started"
assert_nonempty "$ACT" "C: the plain target's worker was started"
assert_contains "$LAB" '[VERIFY]: V1.1' "C: the verify target's PR title is [VERIFY]: <id>"
assert_not_contains "$LAB" '[READY]' "C: the verify target's prompt does not say [READY]"
assert_contains "$LAB" 'Closes #10' "C: the PR body still closes the package issue"
assert_contains "$LAB" 'Do not run the verifier' "C: the worker is told not to run the verifier"
assert_contains "$LAB" 'do not claim any lock it uses' "C: nor claim its lock"
assert_contains "$LAB" 'Do not post a VERIFIED stamp' "C: nor post a VERIFIED stamp"
assert_contains "$LAB" 'npm run test:impacted -- --list prints the selection' "C: ci.verifiedBy says how to list the selection"
assert_not_contains "$LAB" 'must come from that run' "C: the external-gate stamp instruction is not given"

# --- D. a target without verify is unchanged ---------------------------------
assert_contains "$ACT" '[READY]: V1.2' "D: the plain target's PR title is [READY]: <id>"
assert_not_contains "$ACT" '[VERIFY]' "D: the plain target's prompt does not say [VERIFY]"
node -e "
const { buildPrompt } = require('$HERE/../src/launch.js');
const cfg = { repo: 'acme/host', contractPath: '/c.md' };
const base = { issue: { number: 7 }, id: 'X1.1', sc: { branch: 'feat/x', execution: { pattern: 'solo' } }, workerId: 'a', attempt: 1 };
const ext = { repo: 'acme/api', defaultBranch: 'main', ci: { gate: 'external', verifiedBy: 'the lab' } };
const want = [
  'You are worker a executing work package X1.1 (issue #7 in acme/host) in repository acme/api.',
  'Follow the worker contract at /c.md, in order. It governs everything below.',
  'Your lane is .agentic/cells/feat/x/SCOPE.json in this worktree. Execution pattern: solo.',
  'Read the package with: gh issue view 7 --repo acme/host',
  'Branch feat/x is checked out and already pushed. Commit on it. Open the PR against main with a title starting \"[READY]: X1.1\" and a body containing \"Closes #7\".',
  'Do not change any cell:* or worker:* label. Do not edit SCOPE.json. If you need a file outside allowedPaths, stop and write BLOCKER.md.',
  'No GitHub Actions workflow verifies acme/api. Verification for this target: the lab. Your VERIFIED stamp must come from that run, not from a pipeline.',
].join('\n');
const got = buildPrompt(cfg, { ...base, target: ext });
if (got !== want) { console.error(got); process.exit(1); }
" >/dev/null 2>"$TMP/prompt.err"
assert_eq 0 $? "D: an external target without verify gets the prompt it got before, byte for byte"

finish
