#!/usr/bin/env bash
# HV gate: program H, end to end against fixtures. Each scenario runs the real
# script or hook from this tree; nothing under test is stubbed.
#
# 1. Secret. A range that adds a fake token and then removes it fails
#    scripts/check-secrets.sh, naming the commit and not the token. A clean
#    range passes.
# 2. Lane. After `echo x > outside.txt` in a repo with a SCOPE.json lane,
#    enforce-scope.js given the PostToolUse Bash event blocks, naming
#    outside.txt, and require-handoff.js given the Stop event blocks the stop.
# 3. Allow rules. fleet doctor against a target whose settings on the default
#    branch allow Bash(docker *) prints a WARN line naming it.
# 4. Race. CLAUDE_STUB_DELAY=3 bash plugins/fleet/tests/sv1-standards-gate.test.sh
#    ends with 0 failed.
#
# Each scenario has a control beside it (a clean range, an in-lane write,
# narrow allow rules) so a check that always fires cannot pass.
#
# The secret scenario needs the real gitleaks archive: GITLEAKS_ARCHIVE names a
# local copy, otherwise it is downloaded once. With neither, the scenario fails.
# A gate that skips proves nothing. The fake token is built at runtime, so this
# file holds no literal secret.
set -uo pipefail
cd "$(dirname "$0")"
. ../../plugins/fleet/tests/lib.sh

ROOT="$(cd ../.. && pwd -P)"
SECRETS="$ROOT/scripts/check-secrets.sh"
HOOKS="$ROOT/plugins/agentic-work-packages/hooks"
FLEET="$ROOT/plugins/fleet/bin/fleet.js"
STUBS="$ROOT/plugins/fleet/tests/stubs"
SV1="$ROOT/plugins/fleet/tests/sv1-standards-gate.test.sh"
for f in "$SECRETS" "$HOOKS/enforce-scope.js" "$HOOKS/require-handoff.js" "$FLEET" "$SV1"; do
  assert_file "$f" "${f#"$ROOT"/} exists"
done

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
TMP=$(cd "$TMP" && pwd -P)

# repo <dir> — a git repo on main with one clean commit, tagged "base".
repo() {
  mkdir -p "$1"
  git -C "$1" init -q -b main .
  git -C "$1" config user.email hv@example.invalid
  git -C "$1" config user.name hv
  echo 'clean' > "$1/clean.txt"
  git -C "$1" add clean.txt
  git -C "$1" commit -q -m base
  git -C "$1" tag base
}

# --- 1. Secret ---------------------------------------------------------------
PINNED_VERSION=8.30.1
URL="https://github.com/gitleaks/gitleaks/releases/download/v$PINNED_VERSION/gitleaks_${PINNED_VERSION}_linux_x64.tar.gz"
ARCHIVE=""
if [ -n "${GITLEAKS_ARCHIVE:-}" ] && [ -f "$GITLEAKS_ARCHIVE" ]; then
  ARCHIVE="$GITLEAKS_ARCHIVE"
elif curl -fsSL --max-time 60 -o "$TMP/gitleaks.tar.gz" "$URL" 2>/dev/null; then
  ARCHIVE="$TMP/gitleaks.tar.gz"
fi
assert_nonempty "$ARCHIVE" "1: the gitleaks $PINNED_VERSION archive is at hand (GITLEAKS_ARCHIVE, or a download)"

if [ -n "$ARCHIVE" ]; then
  # A GitHub token shape, joined at runtime from a hash.
  FAKE_PAT="gh""p_$(printf 'hv gate fixture' | sha256sum | cut -c1-36)"
  S="$TMP/secret"
  repo "$S"
  echo "TOKEN=$FAKE_PAT" > "$S/deploy.env"
  git -C "$S" add deploy.env && git -C "$S" commit -q -m 'add deploy env'
  LEAK_SHA=$(git -C "$S" rev-parse HEAD)
  git -C "$S" rm -q deploy.env && git -C "$S" commit -q -m 'remove deploy env'
  assert_empty "$(git -C "$S" ls-files deploy.env)" "1: the head tree no longer holds the token"
  OUT=$(cd "$S" && GITLEAKS_ARCHIVE="$ARCHIVE" bash "$SECRETS" base HEAD 2>&1); RC=$?
  assert_eq "1" "$RC" "1: a range that adds a token and then removes it fails"
  assert_contains "$OUT" "commit $LEAK_SHA" "1: the failure names the commit that added the token"
  assert_not_contains "$OUT" "$FAKE_PAT" "1: the token is not printed"
  assert_not_contains "$OUT" "${FAKE_PAT#ghp_}" "1: no part of the token body is printed"

  C="$TMP/clean"
  repo "$C"
  echo 'release notes' > "$C/notes.txt"
  git -C "$C" add notes.txt && git -C "$C" commit -q -m notes
  OUT=$(cd "$C" && GITLEAKS_ARCHIVE="$ARCHIVE" bash "$SECRETS" base HEAD 2>&1); RC=$?
  assert_eq "0" "$RC" "1: a clean range passes"
  assert_contains "$OUT" "PASS  no secrets in base..HEAD" "1: the clean range reports PASS"
fi

# --- 2. Lane -----------------------------------------------------------------
L="$TMP/lane"
repo "$L"
git -C "$L" checkout -q -b feat/hv-lane
mkdir -p "$L/.agentic/cells/feat/hv-lane" "$L/src"
printf '{"feature": "hv-lane", "branch": "feat/hv-lane", "allowedPaths": ["src/**"], "forbiddenPaths": []}\n' \
  > "$L/.agentic/cells/feat/hv-lane/SCOPE.json"
git -C "$L" add .agentic && git -C "$L" commit -q -m 'lane'

# hook <name> <event json> — run a real hook with the event on stdin, in the lane repo.
hook() { (cd "$L" && printf '%s' "$2" | node "$HOOKS/$1" 2>&1); }
# decision <json> — the decision field of a hook's stdout, or "none".
decision() { printf '%s' "$1" | node -e '
  let s = require("fs").readFileSync(0, "utf8");
  try { console.log(JSON.parse(s).decision || "none"); } catch { console.log("none"); }'; }
CMD='echo x > outside.txt'
POST=$(node -e 'console.log(JSON.stringify({hook_event_name: "PostToolUse", tool_name: "Bash",
  tool_input: {command: process.argv[1]}, tool_response: {stdout: "", stderr: ""}, cwd: process.argv[2]}))' "$CMD" "$L")
STOP=$(node -e 'console.log(JSON.stringify({hook_event_name: "Stop", stop_hook_active: false, cwd: process.argv[1]}))' "$L")

# Control: an in-lane write draws no block from either hook. A HANDOFF.md
# with the Plan check is present, so the stop is judged on the lane alone.
printf '# HANDOFF\n\n## Plan check\n\nPackage issue still matches: yes\n' > "$L/.agentic/cells/feat/hv-lane/HANDOFF.md"
(cd "$L" && echo x > src/inside.txt)
OUT=$(hook enforce-scope.js "$POST")
assert_empty "$OUT" "2: an in-lane Bash write draws no output from enforce-scope.js"
OUT=$(hook require-handoff.js "$STOP")
assert_empty "$OUT" "2: an in-lane change does not block the stop"

(cd "$L" && eval "$CMD")
assert_file "$L/outside.txt" "2: the Bash command wrote outside.txt"
OUT=$(hook enforce-scope.js "$POST")
assert_eq "block" "$(decision "$OUT")" "2: enforce-scope.js returns a block after the Bash call"
assert_contains "$OUT" "outside.txt" "2: the block names outside.txt"
assert_not_contains "$OUT" "src/inside.txt" "2: the block does not name the in-lane file"
OUT=$(hook require-handoff.js "$STOP")
assert_eq "block" "$(decision "$OUT")" "2: require-handoff.js blocks the stop with outside.txt present"
assert_contains "$OUT" "outside.txt" "2: the stop block names outside.txt"

# --- 3. Allow rules ----------------------------------------------------------
git init -q --bare -b main "$TMP/remote.git"
git clone -q "$TMP/remote.git" "$TMP/clone" 2>/dev/null
git -C "$TMP/clone" checkout -q -b main 2>/dev/null || true
git -C "$TMP/clone" config user.email hv@example.invalid; git -C "$TMP/clone" config user.name hv
printf '# api\n' > "$TMP/clone/README.md"
git -C "$TMP/clone" add -A && git -C "$TMP/clone" commit -qm init
fixture_standards "$TMP/clone" && git -C "$TMP/clone" push -q -u origin main

# settings <allow rules as a JSON array> — commit and push them on main.
settings() {
  printf '{"enabledPlugins": {"agentic-work-packages@example-market": true}, "permissions": {"allow": %s}}\n' "$1" > "$TMP/clone/.claude/settings.json"
  git -C "$TMP/clone" add .claude/settings.json && git -C "$TMP/clone" commit -qm "fixture: allow rules" && git -C "$TMP/clone" push -q origin main
}

STUB="$TMP/stub"; mkdir -p "$STUB" "$TMP/gh" "$TMP/claude-log"
cp "$STUBS/gh.js" "$STUB/gh.js"
printf '#!/usr/bin/env bash\nexec node "%s/gh.js" "$@"\n' "$STUB" > "$STUB/gh"; chmod +x "$STUB/gh"
cp "$STUBS/claude.sh" "$STUB/claude"; chmod +x "$STUB/claude"
printf '[]' > "$TMP/gh/issues.json"; printf '[]' > "$TMP/gh/prs.json"
printf '{}' > "$TMP/gh/labels.json"; printf '{}' > "$TMP/gh/comments.json"
printf '{}' > "$TMP/gh/ci.json"; : > "$TMP/gh/writes.log"
node -e 'require("fs").writeFileSync(process.argv[1], JSON.stringify({projects: {[process.argv[2]]: {hasTrustDialogAccepted: true}}}))' \
  "$TMP/claude.json" "$TMP/clone"
cat > "$TMP/fleet.config.json" <<JSON
{
  "repo": "acme/host", "epic": 1,
  "targets": [{ "repo": "acme/api", "localPath": "$TMP/clone", "defaultBranch": "main" }],
  "workers": { "a": { "mode": "local" } },
  "wipCap": 4, "worktreesDir": "$TMP/worktrees", "stateDir": "$TMP/state",
  "pluginRoot": "$ROOT/plugins/agentic-work-packages", "noMovementLimit": 99
}
JSON
doctor() {
  (unset CLAUDECODE
   GH_STUB_DIR="$TMP/gh" GH_STUB_REMOTE="$TMP/remote.git" GH_BIN="$STUB/gh" \
   CLAUDE_STUB_LOG="$TMP/claude-log" CLAUDE_STUB_TARGET="acme/api" CLAUDE_BIN="$STUB/claude" \
   CLAUDE_CONFIG_FILE="$TMP/claude.json" node "$FLEET" doctor --config "$TMP/fleet.config.json" 2>/dev/null)
}

settings '["Bash(docker ps:*)", "Bash(git status:*)"]'
WARN=$(doctor | grep '^WARN')
assert_not_contains "$WARN" "Bash(" "3: narrow allow rules draw no WARN line"
settings '["Bash(docker *)", "Bash(git status:*)"]'
WARN=$(doctor | grep '^WARN')
assert_contains "$WARN" "Bash(docker *)" "3: a WARN line names Bash(docker *)"
assert_contains "$(printf '%s\n' "$WARN" | grep -F 'Bash(docker *)')" "acme/api" "3: that WARN line names the target"
assert_not_contains "$WARN" "git status" "3: Bash(git status:*) draws no WARN line"

# --- 4. Race -----------------------------------------------------------------
OUT=$(CLAUDE_STUB_DELAY=3 bash "$SV1" 2>&1); RC=$?
TALLY=$(printf '%s\n' "$OUT" | grep -E -- '--- [0-9]+ checks' | tail -n 1 | sed 's/^ *//')
assert_eq "0" "$RC" "4: sv1-standards-gate.test.sh exits 0 under CLAUDE_STUB_DELAY=3"
assert_contains "$TALLY" " checks, 0 failed" "4: sv1-standards-gate.test.sh ends with 0 failed ($TALLY)"
[ "$RC" -eq 0 ] || printf '%s\n' "$OUT" | grep -E '^ *FAIL' | sed 's/^/        /'

finish
