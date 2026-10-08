#!/usr/bin/env bash
# Fixture test for session-start-install-deps.sh.
#
# npm and gh are stubbed on PATH so the test installs nothing and touches no
# network. What is under test: where it installs, that a failed install is
# reported, and that a repository mismatch is surfaced on stdout (the only
# channel that reaches the model) and never as a non-zero exit.
set -uo pipefail
cd "$(dirname "$0")"
. ./lib.sh

HOOK="$(cd ../hooks && pwd -P)/session-start-install-deps.sh"
assert_file "$HOOK" "the hook under test exists"

TMPROOT=$(mktemp -d)
trap 'rm -rf "$TMPROOT"' EXIT
TMPROOT=$(cd "$TMPROOT" && pwd -P)

STUBS="$TMPROOT/stubs"
mkdir -p "$STUBS"
cat > "$STUBS/npm" <<'EOF'
#!/usr/bin/env bash
echo "npm $* (in $PWD)" >> "$NPM_LOG"
[ "${NPM_FAIL:-0}" = "1" ] && exit 1
exit 0
EOF
chmod +x "$STUBS/npm"

REPO="$TMPROOT/repo"
mkdir -p "$REPO/.claude"
git init -q -b development "$REPO"
git -C "$REPO" remote add origin "git@github.com:acme/widgets.git"
export NPM_LOG="$TMPROOT/npm.log"

# run_hook -> sets EXIT, OUT, ERR
run_hook() {
  : > "$NPM_LOG"
  OUT=$(cd "$TMPROOT" && PATH="$STUBS:$PATH" CLAUDE_PROJECT_DIR="$REPO" bash "$HOOK" 2>"$TMPROOT/stderr")
  EXIT=$?
  ERR=$(cat "$TMPROOT/stderr")
}

# --- 1. no package.json anywhere: skip ---------------------------------------
run_hook
assert_eq 0 "$EXIT" "no package.json: exit 0"
assert_empty "$(cat "$NPM_LOG")" "no package.json: npm is not run"
assert_contains "$ERR" "skipping npm install" "no package.json: says so"

# --- 2. package.json at the root: install there ------------------------------
printf '{}\n' > "$REPO/package.json"
run_hook
assert_eq 0 "$EXIT" "root package.json: exit 0"
assert_contains "$(cat "$NPM_LOG")" "install --prefer-offline (in $REPO)" "installs in the repo root"

# --- 3. monorepo: first package.json one level down --------------------------
rm "$REPO/package.json"
mkdir -p "$REPO/pkg"
printf '{}\n' > "$REPO/pkg/package.json"
run_hook
assert_contains "$(cat "$NPM_LOG")" "(in $REPO/pkg)" "installs in the first subdirectory package"

# --- 4. a failed install is reported with a non-zero exit --------------------
NPM_FAIL=1 run_hook
assert_eq 1 "$EXIT" "failed npm install: exit 1"
assert_contains "$ERR" "npm install failed" "failed npm install: reported on stderr"

# --- 5. repository identity --------------------------------------------------
printf '{ "repo": "acme/widgets" }\n' > "$REPO/.claude/project.json"
run_hook
assert_eq 0 "$EXIT" "matching repo: exit 0"
assert_empty "$OUT" "matching repo: nothing injected into context"
assert_contains "$ERR" "repository identity verified (acme/widgets)" "matching repo: verified"

printf '{ "repo": "acme/other" }\n' > "$REPO/.claude/project.json"
run_hook
assert_eq 0 "$EXIT" "mismatched repo: exit 0, because SessionStart cannot abort and stdout needs exit 0"
assert_contains "$OUT" "REPOSITORY MISMATCH" "mismatched repo: stdout carries the mismatch to the model"
assert_contains "$OUT" "acme/other" "mismatched repo: names the expected repo"
assert_contains "$OUT" "acme/widgets" "mismatched repo: names the actual repo"
assert_contains "$OUT" "BLOCKER.md" "mismatched repo: tells the worker to write BLOCKER.md"
assert_contains "$ERR" "REPOSITORY MISMATCH" "mismatched repo: also on stderr"

# --- 6. https remotes are normalized ----------------------------------------
git -C "$REPO" remote set-url origin "https://github.com/acme/widgets.git"
printf '{ "repo": "acme/widgets" }\n' > "$REPO/.claude/project.json"
run_hook
assert_contains "$ERR" "repository identity verified" "an https origin matches the same repo"

finish
