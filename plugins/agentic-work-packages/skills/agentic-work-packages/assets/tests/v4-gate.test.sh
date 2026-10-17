#!/usr/bin/env bash
# V4 gate, hook half: the Stop hook blocks a HANDOFF.md that has no Plan check
# section and allows one that has it.
#
# Runs against both shipped copies of require-handoff.js, with the handoff at
# the repo root and in the branch's cell directory, so a gap in either copy or
# either location fails the gate.
set -uo pipefail
cd "$(dirname "$0")"
. ./lib.sh

ASSET_HOOK="$(cd ../hooks && pwd -P)/require-handoff.js"
PLUGIN_HOOK="$(cd ../../../../hooks && pwd -P)/require-handoff.js"
assert_file "$ASSET_HOOK" "the asset copy of the hook exists"
assert_file "$PLUGIN_HOOK" "the plugin copy of the hook exists"

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
git -C "$REPO" checkout -q -b feat/g9-1-thing
printf 'work in progress\n' > "$REPO/wip.txt"

# run_stop <hook> -> sets EXIT, OUT, ERR. Run from outside the repo, as an
# installed hook is.
run_stop() {
  local json
  json=$(printf '{"hook_event_name":"Stop","cwd":"%s","stop_hook_active":false}' "$REPO")
  OUT=$(cd "$TMPROOT" && printf '%s' "$json" | node "$1" 2>"$TMPROOT/stderr")
  EXIT=$?
  ERR=$(cat "$TMPROOT/stderr")
}
blocked() { case "$OUT" in *'"decision":"block"'*) return 0 ;; *) return 1 ;; esac; }

WITHOUT=$'# handoff\n\nDone: the change.\nNext: nothing.\n'
WITH=$'# handoff\n\nDone: the change.\n\n## Plan check\n\nPackage issue still matches: yes\n'

for copy in asset plugin; do
  [ "$copy" = asset ] && HOOK="$ASSET_HOOK" || HOOK="$PLUGIN_HOOK"
  for where in root cell; do
    [ "$where" = root ] && DIR="$REPO" || DIR="$REPO/.agentic/cells/feat/g9-1-thing"
    mkdir -p "$DIR"

    # --- a handoff without Plan check is blocked ------------------------------
    printf '%s' "$WITHOUT" > "$DIR/HANDOFF.md"
    run_stop "$HOOK"
    assert_eq 0 "$EXIT" "$copy/$where: the block is a JSON decision, not a crash"
    if blocked; then _pass "$copy/$where: a handoff without Plan check is blocked"
    else _fail "$copy/$where: a handoff without Plan check is blocked" "got [$OUT]"; fi
    assert_contains "$OUT" "Plan check" "$copy/$where: the block names the missing section"
    assert_empty "$ERR" "$copy/$where: the block writes nothing to stderr"

    # --- a handoff with Plan check is allowed ---------------------------------
    printf '%s' "$WITH" > "$DIR/HANDOFF.md"
    run_stop "$HOOK"
    assert_eq 0 "$EXIT" "$copy/$where: allowed with exit 0"
    assert_empty "$OUT" "$copy/$where: a handoff with Plan check is allowed"
    assert_empty "$ERR" "$copy/$where: the allow writes nothing to stderr"

    rm -f "$DIR/HANDOFF.md"
  done
done

finish
