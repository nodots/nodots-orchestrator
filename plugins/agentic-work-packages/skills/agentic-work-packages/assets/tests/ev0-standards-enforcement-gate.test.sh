#!/usr/bin/env bash
# EV0 gate: E0.1 (declared plugins must be enabled), E0.2 (run-checks runs the
# base manifest) and E0.3 hold together on one fixture repo, and each can fail.
#
# One fixture git repo, a `development` base branch and a `change` branch. In
# each case run-checks.js --base development runs against it:
#
#   1. manifest declares example-standard@example-market, tracked settings
#      enable it, one check `true`                       -> exit 0
#   2. the same, plugin not enabled                      -> exit 2, names the plugin
#   3. base check `false`, head rewrites it to `true`    -> exit 1, names the check
#   4. base has no manifest                              -> exit 2, names the base
#
# Placeholder names only. Writes only to a temp directory.
set -uo pipefail
cd "$(dirname "$0")"
. ./lib.sh

SCRIPT="$(cd ../scripts && pwd -P)/run-checks.js"
assert_file "$SCRIPT" "the runner exists"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
TMP=$(cd "$TMP" && pwd -P)

PLUGIN='example-standard@example-market'

git_q() { git -c user.name=fixture -c user.email=fixture@example.invalid -c commit.gpgsign=false "$@"; }

# manifest <command> — a manifest declaring the plugin and one check.
manifest() {
  cat <<EOF
{
  "version": 1,
  "checks": [{ "name": "gate", "command": "$1" }],
  "rules": [],
  "plugins": [{ "name": "example-standard", "marketplace": "example-market" }]
}
EOF
}

# settings <true|false> — tracked settings with the plugin enabled or not.
settings() {
  printf '{ "enabledPlugins": { "%s": %s } }\n' "$PLUGIN" "$1"
}

# fixture <dir> <base-manifest|-> <base-settings|-> <head-manifest> <head-settings>
# A repo with `development` holding the base files (a `-` means the file is
# absent there) and `change` branched from it holding the head files.
fixture() {
  local dir=$1
  mkdir -p "$dir/.claude"
  git_q init -q -b development "$dir"
  printf 'fixture\n' > "$dir/README.md"
  [ "$2" = - ] || printf '%s\n' "$2" > "$dir/.claude/standards.json"
  [ "$3" = - ] || printf '%s\n' "$3" > "$dir/.claude/settings.json"
  git_q -C "$dir" add -A
  git_q -C "$dir" commit -q -m base
  git_q -C "$dir" checkout -q -b change
  printf '%s\n' "$4" > "$dir/.claude/standards.json"
  printf '%s\n' "$5" > "$dir/.claude/settings.json"
  git_q -C "$dir" add -A
  git_q -C "$dir" commit -q --allow-empty -m change
}

# gate <dir> <name> — run the runner; sets RC, OUT (stdout) and ERR (stderr).
gate() {
  RC=0
  node "$SCRIPT" --root "$1" --base development > "$TMP/$2.out" 2> "$TMP/$2.err" || RC=$?
  OUT=$(cat "$TMP/$2.out")
  ERR=$(cat "$TMP/$2.err")
}

# --- 1. declared, enabled, check passes -> 0 ---------------------------------
M_TRUE=$(manifest true)
M_FALSE=$(manifest false)
fixture "$TMP/c1" "$M_TRUE" "$(settings true)" "$M_TRUE" "$(settings true)"
gate "$TMP/c1" c1
assert_eq 0 "$RC" "1 enabled plugin, passing check: exit 0"
assert_contains "$OUT" "PASS  gate" "1: the check is reported PASS"
assert_contains "$OUT" "run-checks: 1 of 1 checks passed (manifest from development)" "1: the tally line"
assert_empty "$ERR" "1: stderr is empty"

# --- 2. declared, not enabled -> 2, naming the plugin ------------------------
fixture "$TMP/c2" "$M_TRUE" "$(settings true)" "$M_TRUE" "$(settings false)"
gate "$TMP/c2" c2
assert_eq 2 "$RC" "2 plugin not enabled: exit 2"
assert_contains "$ERR" "$PLUGIN is not enabled in .claude/settings.json" "2: stderr names $PLUGIN"
assert_not_contains "$OUT" "PASS" "2: no check ran"

# --- 3. head rewrites a failing base check to pass -> 1 ----------------------
fixture "$TMP/c3" "$M_FALSE" "$(settings true)" "$M_TRUE" "$(settings true)"
gate "$TMP/c3" c3
assert_eq 1 "$RC" "3 check rewritten by its own PR: exit 1"
assert_contains "$OUT" "FAIL  gate (exit 1)" "3: the base check ran and failed"
assert_contains "$OUT" "run-checks: 0 of 1 checks passed (manifest from development)" "3: the tally line"

# --- 4. base has no manifest -> 2 --------------------------------------------
fixture "$TMP/c4" - "$(settings true)" "$M_TRUE" "$(settings true)"
gate "$TMP/c4" c4
assert_eq 2 "$RC" "4 base without a manifest: exit 2"
assert_contains "$ERR" "run-checks: no .claude/standards.json at development" "4: stderr names the missing base manifest"
assert_not_contains "$OUT" "PASS" "4: no check ran"

finish
