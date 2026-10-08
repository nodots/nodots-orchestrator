#!/usr/bin/env bash
# Fixture test for enforce-scope-staged.js.
#
# Real git repos. What is under test: no SCOPE.json is unrestricted, an
# out-of-lane staged file is refused and named, coordination files and cell
# directories resolve as enforce-scope.js resolves them, and a broken
# SCOPE.json fails open and says so.
set -uo pipefail
cd "$(dirname "$0")"
. ./lib.sh

HOOK="$(cd ../hooks && pwd -P)/enforce-scope-staged.js"
assert_file "$HOOK" "the hook under test exists"

TMPROOT=$(mktemp -d)
trap 'rm -rf "$TMPROOT"' EXIT
TMPROOT=$(cd "$TMPROOT" && pwd -P)

REPO="$TMPROOT/repo"
mkdir -p "$REPO"
git init -q -b development "$REPO"
git -C "$REPO" config user.email "fixture@example.invalid"
git -C "$REPO" config user.name "Fixture"
printf '# readme\n' > "$REPO/README.md"
git -C "$REPO" add -A
git -C "$REPO" commit -qm "fixture"
git -C "$REPO" checkout -q -b feat/thing

# run_hook -> sets EXIT, ERR. Runs from inside the repo, as git runs a hook.
run_hook() {
  (cd "$REPO" && node "$HOOK" 2>"$TMPROOT/stderr")
  EXIT=$?
  ERR=$(cat "$TMPROOT/stderr")
}

stage() { mkdir -p "$REPO/$(dirname "$1")"; printf 'x\n' > "$REPO/$1"; git -C "$REPO" add -- "$1"; }
unstage_all() { git -C "$REPO" reset -q; rm -rf "$REPO/src" "$REPO/docs" "$REPO/odd dir" "$REPO/SCOPE.json" "$REPO/HANDOFF.md" "$REPO/.agentic"; }

# --- 1. no SCOPE.json: unrestricted ------------------------------------------
stage src/anything.ts
run_hook
assert_eq 0 "$EXIT" "no SCOPE.json: exit 0"
assert_empty "$ERR" "no SCOPE.json: silent"
unstage_all

# --- 2. root SCOPE.json: in lane passes, out of lane is refused and named ----
cat > "$REPO/SCOPE.json" <<'EOF'
{ "allowedPaths": ["src/**", "test/**"], "forbiddenPaths": ["src/secret/**"] }
EOF
stage src/a.ts
run_hook
assert_eq 0 "$EXIT" "in-lane file: exit 0"
unstage_all
cat > "$REPO/SCOPE.json" <<'EOF'
{ "allowedPaths": ["src/**", "test/**"], "forbiddenPaths": ["src/secret/**"] }
EOF

stage src/a.ts; stage docs/out.md
run_hook
assert_eq 1 "$EXIT" "out-of-lane file: exit 1 refuses the commit"
assert_contains "$ERR" "docs/out.md" "the refusal names the offending file"
assert_contains "$ERR" "not in allowedPaths" "the refusal says why"
assert_not_contains "$ERR" "src/a.ts" "the in-lane file is not named"
assert_contains "$ERR" "BLOCKER.md" "the refusal points at BLOCKER.md"
unstage_all
cat > "$REPO/SCOPE.json" <<'EOF'
{ "allowedPaths": ["src/**", "test/**"], "forbiddenPaths": ["src/secret/**"] }
EOF

stage src/secret/key.ts
run_hook
assert_eq 1 "$EXIT" "forbiddenPaths beats allowedPaths"
assert_contains "$ERR" "matches forbiddenPaths" "the refusal names forbiddenPaths"
git -C "$REPO" reset -q; rm -rf "$REPO/src"

# --- 3. coordination files are always committable ----------------------------
stage HANDOFF.md
run_hook
assert_eq 0 "$EXIT" "HANDOFF.md is committable whatever the lane"
git -C "$REPO" reset -q; rm -f "$REPO/HANDOFF.md"

# --- 4. a path with a space is judged, not mangled ---------------------------
stage "odd dir/file.txt"
run_hook
assert_eq 1 "$EXIT" "a path with a space is refused when out of lane"
assert_contains "$ERR" "odd dir/file.txt" "the path with a space is named intact"
git -C "$REPO" reset -q; rm -rf "$REPO/odd dir"

# --- 5. the branch cell directory is preferred over the root file ------------
mkdir -p "$REPO/.agentic/cells/feat/thing"
cat > "$REPO/.agentic/cells/feat/thing/SCOPE.json" <<'EOF'
{ "allowedPaths": ["docs/**"], "forbiddenPaths": [] }
EOF
stage docs/ok.md
run_hook
assert_eq 0 "$EXIT" "the cell-directory SCOPE.json governs: docs/** is allowed"
git -C "$REPO" reset -q
stage src/a.ts
run_hook
assert_eq 1 "$EXIT" "the cell-directory SCOPE.json governs: src/** is refused"
git -C "$REPO" reset -q; rm -rf "$REPO/.agentic" "$REPO/src" "$REPO/docs"

# --- 6. fail open, and loud --------------------------------------------------
printf 'not json' > "$REPO/SCOPE.json"
stage src/a.ts
run_hook
assert_eq 0 "$EXIT" "unreadable SCOPE.json fails open"
assert_contains "$ERR" "enforce-scope-staged" "the failure is reported on stderr, naming the script"

finish
