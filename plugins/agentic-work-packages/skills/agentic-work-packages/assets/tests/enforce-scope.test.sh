#!/usr/bin/env bash
# Fixture test for enforce-scope.js (N-1, N-12, N-15).
#
# Proves the hook enforces the lane from BOTH install locations. The defect it
# pins: the hook used to derive the repo root from its own file location, which
# is the repo under a manual .claude/hooks/ install and the plugin's parent
# directory under a plugin install — so under the plugin install SCOPE.json was
# never found and every path was allowed.
#
# Every row runs the hook from a directory outside the fixture repo, which is
# how a plugin-installed hook actually runs.
set -uo pipefail
cd "$(dirname "$0")"
. ./lib.sh

HOOK_SRC="$(cd ../hooks && pwd -P)/enforce-scope.js"
assert_file "$HOOK_SRC" "the hook under test exists"

TMPROOT=$(mktemp -d)
trap 'rm -rf "$TMPROOT"' EXIT
TMPROOT=$(cd "$TMPROOT" && pwd -P)   # physical path: git reports physical paths

ERRFILE="$TMPROOT/stderr"

# --- fixture repo: branch feat/thing, root SCOPE.json ------------------------
REPO="$TMPROOT/repo"
mkdir -p "$REPO/src"
git init -q -b feat/thing "$REPO"
git -C "$REPO" config user.email "fixture@example.invalid"
git -C "$REPO" config user.name "Fixture"
cat > "$REPO/SCOPE.json" <<'JSON'
{
  "feature": "thing",
  "project": "fixture",
  "branch": "feat/thing",
  "allowedPaths": ["src/**"],
  "forbiddenPaths": ["package.json"],
  "dependsOn": [],
  "estimatedScope": "fixture"
}
JSON
printf 'x\n' > "$REPO/src/a.ts"
printf '# readme\n' > "$REPO/README.md"
printf '{}\n' > "$REPO/package.json"
git -C "$REPO" add -A
git -C "$REPO" commit -qm "fixture"

# --- second repo with no SCOPE.json ------------------------------------------
NOSCOPE="$TMPROOT/noscope"
mkdir -p "$NOSCOPE"
git init -q -b feat/thing "$NOSCOPE"
git -C "$NOSCOPE" config user.email "fixture@example.invalid"
git -C "$NOSCOPE" config user.name "Fixture"
printf '# readme\n' > "$NOSCOPE/README.md"
git -C "$NOSCOPE" add -A
git -C "$NOSCOPE" commit -qm "fixture"

# --- the two install shapes ---------------------------------------------------
# manual: the hook sits at <repo>/.claude/hooks/, so <here>/../.. IS the repo.
mkdir -p "$REPO/.claude/hooks" "$NOSCOPE/.claude/hooks"
cp "$HOOK_SRC" "$REPO/.claude/hooks/enforce-scope.js"
cp "$HOOK_SRC" "$NOSCOPE/.claude/hooks/enforce-scope.js"
MANUAL="$REPO/.claude/hooks/enforce-scope.js"
MANUAL_NOSCOPE="$NOSCOPE/.claude/hooks/enforce-scope.js"

# plugin: the hook sits outside the repo, so <here>/../.. is NOT the repo.
mkdir -p "$TMPROOT/fake-plugin/hooks"
cp "$HOOK_SRC" "$TMPROOT/fake-plugin/hooks/enforce-scope.js"
PLUGIN="$TMPROOT/fake-plugin/hooks/enforce-scope.js"

# run_hook <hook> <abs file path> [cwd]   ("-" for a cwd-less event)
# Sets EXIT, OUT, ERR. Always invoked from outside the fixture repo.
run_hook() {
  local hook="$1" file="$2" cwd="${3:--}" json
  if [ "$cwd" = "-" ]; then
    json=$(printf '{"hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{"file_path":"%s"}}' "$file")
  else
    json=$(printf '{"hook_event_name":"PreToolUse","cwd":"%s","tool_name":"Edit","tool_input":{"file_path":"%s"}}' "$cwd" "$file")
  fi
  OUT=$(cd "$TMPROOT" && printf '%s' "$json" | node "$hook" 2>"$ERRFILE")
  EXIT=$?
  ERR=$(cat "$ERRFILE")
}

# --- the evaluation's table ---------------------------------------------------
# | install | file                      | expected |
run_hook "$MANUAL" "$REPO/README.md" "$REPO"
assert_eq 2 "$EXIT" "manual  · README.md (out of lane) denied"

run_hook "$MANUAL" "$REPO/src/a.ts" "$REPO"
assert_eq 0 "$EXIT" "manual  · src/a.ts (in lane) allowed"

run_hook "$MANUAL" "$REPO/package.json" "$REPO"
assert_eq 2 "$EXIT" "manual  · package.json (forbidden) denied"

run_hook "$PLUGIN" "$REPO/README.md" "$REPO"
assert_eq 2 "$EXIT" "plugin  · README.md (out of lane) denied"

run_hook "$PLUGIN" "$REPO/src/a.ts" "$REPO"
assert_eq 0 "$EXIT" "plugin  · src/a.ts (in lane) allowed"

run_hook "$PLUGIN" "$REPO/package.json" "$REPO"
assert_eq 2 "$EXIT" "plugin  · package.json (forbidden) denied"

run_hook "$MANUAL_NOSCOPE" "$NOSCOPE/README.md" "$NOSCOPE"
assert_eq 0 "$EXIT" "manual  · no SCOPE.json means no restriction"

# --- the cwd-absent fallback --------------------------------------------------
run_hook "$MANUAL" "$REPO/README.md" "-"
assert_eq 2 "$EXIT" "manual  · no cwd in the event falls back to the hook's own location"

run_hook "$PLUGIN" "$REPO/README.md" "-"
assert_eq 0 "$EXIT" "plugin  · no cwd in the event cannot find the repo (the fallback's residue)"

# --- N-15: deny, never ask ----------------------------------------------------
run_hook "$PLUGIN" "$REPO/README.md" "$REPO"
assert_empty "$OUT" "deny writes nothing to stdout — no permission-ask JSON"
assert_nonempty "$ERR" "deny states the reason on stderr"
assert_contains "$ERR" "BLOCKER.md" "the deny message names the escalation route"
assert_not_contains "$OUT" "permissionDecision" "the hook never returns a permission decision object"

# --- coordination files stay writable ----------------------------------------
for f in SCOPE.json HANDOFF.md BLOCKER.md; do
  run_hook "$PLUGIN" "$REPO/$f" "$REPO"
  assert_eq 0 "$EXIT" "plugin  · $f is always writable"
done

# --- N-12: a hook that cannot evaluate says so, and still fails open ----------
printf 'not json at all' > "$REPO/SCOPE.json"
run_hook "$PLUGIN" "$REPO/README.md" "$REPO"
assert_eq 0 "$EXIT" "malformed SCOPE.json fails open"
assert_nonempty "$ERR" "malformed SCOPE.json is reported on stderr"
assert_contains "$ERR" "enforce-scope" "the stderr notice names the hook"

OUT=$(cd "$TMPROOT" && printf 'not json' | node "$PLUGIN" 2>"$ERRFILE")
EXIT=$?
ERR=$(cat "$ERRFILE")
assert_eq 0 "$EXIT" "malformed hook input fails open"
assert_contains "$ERR" "enforce-scope" "malformed hook input is reported on stderr"

# --- the two shipped copies must not drift -----------------------------------
if diff -q "$HOOK_SRC" ../../../../hooks/enforce-scope.js >/dev/null 2>&1; then
  _pass "the plugin and asset copies of the hook are byte-identical"
else
  _fail "the plugin and asset copies of the hook are byte-identical" "they differ"
fi

finish
