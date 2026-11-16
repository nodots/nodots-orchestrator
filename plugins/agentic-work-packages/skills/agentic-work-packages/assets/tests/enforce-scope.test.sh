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

# --- H0.2: PostToolUse Bash mode ---------------------------------------------
# A write made through Bash is judged right after the call, from the worktree's
# actual state. The fixture branches off development, so a merge base exists.
BASH_REPO="$TMPROOT/bash-repo"
CELL="$BASH_REPO/.agentic/cells/feat/thing"
mkdir -p "$BASH_REPO/src"
git init -q -b development "$BASH_REPO"
git -C "$BASH_REPO" config user.email "fixture@example.invalid"
git -C "$BASH_REPO" config user.name "Fixture"
printf '# readme\n' > "$BASH_REPO/README.md"
printf 'x\n' > "$BASH_REPO/src/a.ts"
git -C "$BASH_REPO" add -A
git -C "$BASH_REPO" commit -qm "fixture"
git -C "$BASH_REPO" branch main            # a stale default, behind development
printf 'more\n' >> "$BASH_REPO/README.md"
git -C "$BASH_REPO" commit -qam "development moves on, outside the lane"
git -C "$BASH_REPO" checkout -q -b feat/thing
mkdir -p "$CELL"
cat > "$CELL/SCOPE.json" <<'JSON'
{ "allowedPaths": ["src/**"], "forbiddenPaths": ["src/secret/**"] }
JSON
git -C "$BASH_REPO" add -A
git -C "$BASH_REPO" commit -qm "scope"

# run_bash_post <cwd> [command]  -> sets EXIT, OUT, ERR
run_bash_post() {
  local json
  json=$(printf '{"hook_event_name":"PostToolUse","cwd":"%s","tool_name":"Bash","tool_input":{"command":"%s"},"tool_response":{}}' "$1" "${2:-true}")
  OUT=$(cd "$TMPROOT" && printf '%s' "$json" | node "$PLUGIN" 2>"$ERRFILE")
  EXIT=$?
  ERR=$(cat "$ERRFILE")
}
post_blocked() { case "$OUT" in *'"decision":"block"'*) return 0 ;; *) return 1 ;; esac; }

# the clean branch: the scope commit and a stale main do not count against it
run_bash_post "$BASH_REPO"
assert_eq 0 "$EXIT" "bash    · clean branch: exit 0"
assert_empty "$OUT" "bash    · clean branch: no block (closest base, not the stale main)"

# echo > outside.txt is blocked and named
(cd "$BASH_REPO" && echo x > outside.txt)
run_bash_post "$BASH_REPO" "echo x > outside.txt"
assert_eq 0 "$EXIT" "bash    · out-of-lane write: the block is a JSON decision, exit 0"
if post_blocked; then _pass "bash    · echo > outside.txt is blocked at PostToolUse"
else _fail "bash    · echo > outside.txt is blocked at PostToolUse" "got [$OUT]"; fi
assert_contains "$OUT" "outside.txt" "bash    · the block names the path"
assert_contains "$OUT" "BLOCKER.md" "bash    · the block names the escalation route"
assert_contains "$OUT" "revert" "bash    · the block tells the worker to revert"
rm -f "$BASH_REPO/outside.txt"

# an in-lane write passes
(cd "$BASH_REPO" && echo y > src/b.ts)
run_bash_post "$BASH_REPO" "echo y > src/b.ts"
assert_empty "$OUT" "bash    · in-lane write passes"
assert_empty "$ERR" "bash    · in-lane write is silent"

# lane artifacts in the cell directory pass
(cd "$BASH_REPO" && printf '# h\n' > "$CELL/HANDOFF.md" && printf '# b\n' > "$CELL/BLOCKER.md" \
  && printf '{"allowedPaths":["src/**"],"forbiddenPaths":["src/secret/**"]}\n' > "$CELL/SCOPE.json")
run_bash_post "$BASH_REPO"
assert_empty "$OUT" "bash    · lane-artifact writes pass"
git -C "$BASH_REPO" checkout -q -- "$CELL/SCOPE.json"
rm -f "$CELL/HANDOFF.md" "$CELL/BLOCKER.md"

# forbiddenPaths wins over allowedPaths
mkdir -p "$BASH_REPO/src/secret"
(cd "$BASH_REPO" && echo z > src/secret/key.ts)
run_bash_post "$BASH_REPO"
if post_blocked; then _pass "bash    · a forbidden path inside allowedPaths is blocked"
else _fail "bash    · a forbidden path inside allowedPaths is blocked" "got [$OUT]"; fi
assert_contains "$OUT" "src/secret/key.ts" "bash    · the forbidden path is named"
rm -rf "$BASH_REPO/src/secret"

# a modified tracked file, and a path with a space, are named exactly
printf 'edit\n' >> "$BASH_REPO/README.md"
mkdir -p "$BASH_REPO/odd dir"
printf 'x\n' > "$BASH_REPO/odd dir/f.txt"
run_bash_post "$BASH_REPO"
assert_contains "$OUT" "README.md" "bash    · a modified tracked file is named"
assert_contains "$OUT" "odd dir/f.txt" "bash    · a path with a space is named exactly"
git -C "$BASH_REPO" checkout -q -- README.md
rm -rf "$BASH_REPO/odd dir"

# a commit made in the call is caught against the merge base, on a clean tree
mkdir -p "$BASH_REPO/docs"
printf 'x\n' > "$BASH_REPO/docs/note.md"
git -C "$BASH_REPO" add docs/note.md
git -C "$BASH_REPO" commit -qm "out of lane, committed"
run_bash_post "$BASH_REPO" "git commit -m x"
if post_blocked; then _pass "bash    · an out-of-lane commit made in the call is blocked"
else _fail "bash    · an out-of-lane commit made in the call is blocked" "got [$OUT]"; fi
assert_contains "$OUT" "docs/note.md" "bash    · the committed path is named"
git -C "$BASH_REPO" reset -q --hard HEAD~1

# merging development into the branch does not put development's files in the lane check
git -C "$BASH_REPO" checkout -q development
printf 'again\n' >> "$BASH_REPO/README.md"
git -C "$BASH_REPO" commit -qam "development moves again"
git -C "$BASH_REPO" checkout -q feat/thing
git -C "$BASH_REPO" merge -q --no-edit development
run_bash_post "$BASH_REPO" "git merge development"
assert_empty "$OUT" "bash    · a merge of development is not an out-of-lane change"

# a repo with no SCOPE.json is unaffected
(cd "$NOSCOPE" && echo x > outside.txt)
run_bash_post "$NOSCOPE" "echo x > outside.txt"
assert_eq 0 "$EXIT" "bash    · no SCOPE.json: exit 0"
assert_empty "$OUT" "bash    · no SCOPE.json: no block"
assert_empty "$ERR" "bash    · no SCOPE.json: silent"
rm -f "$NOSCOPE/outside.txt"

# a Bash event at PreToolUse has no file_path and stays a no-op
json=$(printf '{"hook_event_name":"PreToolUse","cwd":"%s","tool_name":"Bash","tool_input":{"command":"echo x > outside.txt"}}' "$BASH_REPO")
OUT=$(cd "$TMPROOT" && printf '%s' "$json" | node "$PLUGIN" 2>"$ERRFILE"); EXIT=$?
assert_eq 0 "$EXIT" "bash    · a PreToolUse Bash event is not judged"
assert_empty "$OUT" "bash    · a PreToolUse Bash event writes nothing"

# fail open, and loud, in the Bash mode too
printf 'not json' > "$CELL/SCOPE.json"
run_bash_post "$BASH_REPO"
assert_eq 0 "$EXIT" "bash    · malformed SCOPE.json fails open"
assert_empty "$OUT" "bash    · malformed SCOPE.json does not block"
assert_contains "$ERR" "enforce-scope" "bash    · malformed SCOPE.json is reported on stderr"
git -C "$BASH_REPO" checkout -q -- "$CELL/SCOPE.json"

# the plugin wiring sends PostToolUse Bash to this hook
if node -e '
  const s = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
  const post = (s.hooks && s.hooks.PostToolUse) || [];
  const ok = post.some(e => e.matcher === "Bash" &&
    (e.hooks || []).some(h => (h.command || "").includes("enforce-scope.js")));
  process.exit(ok ? 0 : 1);
' ../../../../hooks/hooks.json; then
  _pass "hooks.json wires PostToolUse Bash to enforce-scope.js"
else
  _fail "hooks.json wires PostToolUse Bash to enforce-scope.js" "no such matcher"
fi

# --- the lane matcher is copied, not shared: the two copies must not drift ----
lane_region() { sed -n '/^\/\/ --- lane matcher: begin/,/^\/\/ --- lane matcher: end/p' "$1"; }
ES_REGION=$(lane_region "$HOOK_SRC")
RH_REGION=$(lane_region "$(dirname "$HOOK_SRC")/require-handoff.js")
assert_nonempty "$ES_REGION" "enforce-scope.js carries the lane matcher region"
assert_nonempty "$RH_REGION" "require-handoff.js carries the lane matcher region"
if [ -n "$ES_REGION" ] && [ "$ES_REGION" = "$RH_REGION" ]; then
  _pass "the lane matcher is identical in enforce-scope.js and require-handoff.js"
else
  _fail "the lane matcher is identical in enforce-scope.js and require-handoff.js" "the regions differ"
fi

# --- the two shipped copies must not drift -----------------------------------
if diff -q "$HOOK_SRC" ../../../../hooks/enforce-scope.js >/dev/null 2>&1; then
  _pass "the plugin and asset copies of the hook are byte-identical"
else
  _fail "the plugin and asset copies of the hook are byte-identical" "they differ"
fi

finish
