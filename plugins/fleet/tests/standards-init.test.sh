#!/usr/bin/env bash
# fleet standards init: drafts a target's .claude/standards.json from what the
# clone already has, prints it, and validates it with the plugin's
# check-standards.js. It never stages, commits or pushes, and it never guesses
# a check it cannot see.
set -uo pipefail
cd "$(dirname "$0")"
. ./lib.sh

FLEET="$(cd .. && pwd -P)/bin/fleet.js"
PLUGIN="$(cd ../../agentic-work-packages && pwd -P)"
CHECK="$PLUGIN/skills/agentic-work-packages/assets/scripts/check-standards.js"
assert_file "$FLEET" "fleet.js exists"
assert_file "$CHECK" "check-standards.js exists"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
TMP=$(cd "$TMP" && pwd -P)

new_clone() { # dir
  git init -q -b main "$1"
  git -C "$1" config user.email f@example.invalid; git -C "$1" config user.name fixture
}

# A clone with package.json scripts (in an order unlike the draft's), a
# CLAUDE.md and a worker contract, which is never a rule.
A="$TMP/api"; new_clone "$A"
cat > "$A/package.json" <<'JSON'
{ "name": "api", "scripts": { "test": "node t.js", "start": "node .", "build": "tsc", "lint": "eslint .", "typecheck": "tsc --noEmit" } }
JSON
printf '# api\n' > "$A/CLAUDE.md"
mkdir -p "$A/.claude"; printf '# contract\n' > "$A/.claude/worker-contract.md"
git -C "$A" add -A && git -C "$A" commit -qm init

# A clone with no package.json.
B="$TMP/docs"; new_clone "$B"
printf '# docs\n' > "$B/AGENTS.md"
git -C "$B" add -A && git -C "$B" commit -qm init

cat > "$TMP/fleet.config.json" <<JSON
{
  "repo": "acme/host", "epic": 1,
  "targets": [
    { "repo": "acme/api", "localPath": "$A", "defaultBranch": "main" },
    { "repo": "acme/docs", "localPath": "$B", "defaultBranch": "main" }
  ],
  "workers": { "a": { "mode": "local" } },
  "wipCap": 4, "worktreesDir": "$TMP/worktrees", "stateDir": "$TMP/state",
  "pluginRoot": "$PLUGIN", "noMovementLimit": 99
}
JSON
fleet() { node "$FLEET" "$@" --config "$TMP/fleet.config.json"; }
# field <json> <path> -> the value at m.<path>, as JSON; keys <json> -> its top-level keys
keys() { printf '%s' "$1" | node -e "console.log(JSON.stringify(Object.keys(JSON.parse(require('fs').readFileSync(0,'utf8')))))"; }
field() { printf '%s' "$1" | node -e "const m=JSON.parse(require('fs').readFileSync(0,'utf8')); console.log(JSON.stringify(eval('m.'+process.argv[1])))" "$2"; }

# --- A. scripts and CLAUDE.md: the draft, in order, and it validates ----------
HEAD_A=$(git -C "$A" rev-parse HEAD)
OUT=$(fleet standards init --target acme/api 2>"$TMP/err"); EXIT=$?
ERR=$(cat "$TMP/err")
assert_eq 0 "$EXIT" "A: a draft that validates exits 0"
assert_eq '[{"name":"lint","command":"npm run lint"},{"name":"typecheck","command":"npm run typecheck"},{"name":"build","command":"npm run build"},{"name":"test","command":"npm test"}]' "$(field "$OUT" checks)" "A: checks are lint, typecheck, build, test, in that order"
assert_eq '[{"doc":"CLAUDE.md","check":null}]' "$(field "$OUT" rules)" "A: CLAUDE.md is a rule; the worker contract is not"
assert_eq 1 "$(field "$OUT" version)" "A: version is 1"
assert_eq '["version","checks","rules"]' "$(keys "$OUT")" "A: no preamble, no plugins"
assert_contains "$ERR" "package.json" "A: the notes on stderr say what was found"
assert_contains "$ERR" "validates" "A: stderr says the draft validates"
assert_not_contains "$OUT" "validates" "A: stdout is the draft JSON only"
printf '%s' "$OUT" > "$TMP/draft-a.json"
node "$CHECK" --root "$A" "$TMP/draft-a.json" 2>/dev/null
assert_eq 0 "$?" "A: check-standards.js accepts the printed draft"
assert_empty "$(git -C "$A" status --porcelain)" "A: a dry init leaves the clone untouched"

# --- B. no package.json: empty checks, the note, exit 1 -----------------------
OUT=$(fleet standards init --target acme/docs 2>"$TMP/err"); EXIT=$?
ERR=$(cat "$TMP/err")
assert_eq 1 "$EXIT" "B: a draft that does not validate exits 1"
assert_eq '[]' "$(field "$OUT" checks)" "B: checks[] is empty"
assert_eq '[{"doc":"AGENTS.md","check":null}]' "$(field "$OUT" rules)" "B: AGENTS.md is a rule"
assert_contains "$ERR" "no package.json: checks[] is empty; add the repo's check commands before this validates" "B: the note is on stderr"
assert_contains "$ERR" "does not validate" "B: stderr says the draft does not validate"

# --- C. --write creates the file once, and stages or commits nothing ----------
OUT=$(fleet standards init --target acme/api --write 2>"$TMP/err"); EXIT=$?
assert_eq 0 "$EXIT" "C: --write exits 0 for a draft that validates"
assert_file "$A/.claude/standards.json" "C: --write creates .claude/standards.json"
assert_eq "$(cat "$TMP/draft-a.json")" "$(cat "$A/.claude/standards.json" | node -e "process.stdout.write(JSON.stringify(JSON.parse(require('fs').readFileSync(0,'utf8')),null,2))")" "C: the written file is the draft"
node "$CHECK" --root "$A" 2>/dev/null
assert_eq 0 "$?" "C: check-standards.js accepts the written file"
BEFORE=$(cat "$A/.claude/standards.json")
printf '{"edited":true}\n' > "$A/.claude/standards.json"
OUT=$(fleet standards init --target acme/api --write 2>"$TMP/err"); EXIT=$?
assert_eq 1 "$EXIT" "C: a second --write is refused with exit 1"
assert_contains "$(cat "$TMP/err")" "exists" "C: the refusal says the file exists"
assert_eq '{"edited":true}' "$(cat "$A/.claude/standards.json")" "C: the existing file is not overwritten"
assert_eq "?? .claude/standards.json" "$(git -C "$A" status --porcelain)" "C: nothing is staged; the file is untracked"
assert_eq "$HEAD_A" "$(git -C "$A" rev-parse HEAD)" "C: nothing is committed"

# --- D. usage errors ----------------------------------------------------------
OUT=$(fleet standards init --target acme/nope 2>&1); EXIT=$?
assert_eq 64 "$EXIT" "D: a target not in targets[] is a usage error"
assert_contains "$OUT" "acme/nope" "D: the error names the target"
OUT=$(fleet standards init 2>&1); EXIT=$?
assert_eq 64 "$EXIT" "D: no --target is a usage error"
OUT=$(fleet standards 2>&1); EXIT=$?
assert_eq 64 "$EXIT" "D: fleet standards with no subcommand is a usage error"
assert_contains "$OUT" "standards init" "D: usage text lists standards init"

finish
