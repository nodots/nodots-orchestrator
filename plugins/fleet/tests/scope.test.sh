#!/usr/bin/env bash
# Fixture test for src/scope.js: the issue body is the source of truth for
# SCOPE.json, and a package the runtime cannot launch safely is refused with
# the reason named.
set -uo pipefail
cd "$(dirname "$0")"
. ./lib.sh

SRC="$(cd .. && pwd -P)/src/scope.js"
assert_file "$SRC" "scope.js exists"

js() { node -e "const s=require('$SRC'); $1"; }

BODY='**Part of** #1 · **Phase 1 · x** · **Repo:** `acme/api`

## Goal
Something.

### SCOPE.json
```json
{"feature":"f","branch":"feat/t1-2-thing","allowedPaths":["src/**","test/**"],"forbiddenPaths":["contracts/**"],"dependsOn":["feat/t1-0-schema"],"execution":{"model":"default","pattern":"solo"}}
```

## Acceptance criteria
- [ ] x'

OUT=$(BODY="$BODY" js "const d=s.describe({title:'T1.2 Thing', body:process.env.BODY}); console.log(d.id, d.problems.length, d.scope.branch, d.scope.dependsOn.join(','))")
assert_eq "T1.2 0 feat/t1-2-thing feat/t1-0-schema" "$OUT" "a well-formed package yields id, scope and no problems"

assert_eq "t1-2" "$(js "console.log(s.slug('T1.2'))")" "slug lowercases and turns . into -"
assert_eq "t5-0d" "$(js "console.log(s.slug('T5.0d'))")" "a letter-suffixed id keeps its suffix"
assert_eq "/w/api-t1-2" "$(js "console.log(s.worktreePath('/w','acme/api','T1.2'))")" "worktree is <dir>/<repoName>-<slug>"
assert_eq "T5.0d" "$(js "console.log(s.packageId('T5.0d: carrier contracts'))")" "package id is the first token with trailing punctuation stripped"

# Refusals, each named.
OUT=$(js "console.log(s.describe({title:'X y', body:'no block here'}).problems.join('|'))")
assert_contains "$OUT" "no SCOPE.json heading" "a body with no block is refused"

OUT=$(js "console.log(s.describe({title:'X y', body:'### SCOPE.json\n\`\`\`json\n{not json\n\`\`\`'}).problems.join('|'))")
assert_contains "$OUT" "not valid JSON" "an unparseable block is refused"

OUT=$(js "console.log(s.validate({branch:'feat/ok',allowedPaths:[]}).join('|'))")
assert_contains "$OUT" "allowedPaths is empty" "an empty lane is refused"

for b in '-evil' 'a..b' 'has space' 'feat/x.lock' ''; do
  OUT=$(B="$b" js "console.log(s.validate({branch:process.env.B,allowedPaths:['x']}).join('|'))")
  assert_contains "$OUT" "unsafe" "branch [$b] is refused as unsafe"
done

OUT=$(js "console.log(s.validate({branch:'feat/ok',allowedPaths:['x'],execution:{pattern:'yolo'}}).join('|'))")
assert_contains "$OUT" "execution.pattern" "an unknown execution pattern is refused"
OUT=$(js "console.log(s.validate({branch:'feat/ok',allowedPaths:['x'],execution:{model:'gpt'}}).join('|'))")
assert_contains "$OUT" "execution.model" "an unknown model tier is refused"
OUT=$(js "console.log(s.validate({branch:'feat/ok',allowedPaths:['x'],execution:{mode:'cloud',pattern:'implement+test',model:'strongest'}}).length)")
assert_eq "0" "$OUT" "a full execution block with known values passes"

# A lane that is also forbidden cannot be worked.
OUT=$(js "console.log(s.validate({branch:'feat/ok',allowedPaths:['src/**','tests/**'],forbiddenPaths:['src/**']}).join('|'))")
assert_contains "$OUT" "allowedPaths [src/**] is covered by forbiddenPaths [src/**]" "an allowed pattern that is also forbidden is refused"
OUT=$(js "console.log(s.validate({branch:'feat/ok',allowedPaths:['src/portal/**'],forbiddenPaths:['src/**']}).join('|'))")
assert_contains "$OUT" "covered by forbiddenPaths [src/**]" "an allowed subtree under a forbidden dir/** is refused"
OUT=$(js "console.log(s.validate({branch:'feat/ok',allowedPaths:['src/**'],forbiddenPaths:['src/secret/**','contracts/**']}).length)")
assert_eq "0" "$OUT" "a forbidden subtree inside an allowed lane is fine (that is what forbiddenPaths is for)"

# A fenced block without the json tag, and a block before any heading, still parse.
OUT=$(js "console.log(s.extract('### SCOPE.json\n\`\`\`\n{\"branch\":\"feat/a\",\"allowedPaths\":[\"a\"]}\n\`\`\`').scope.branch)")
assert_eq "feat/a" "$OUT" "an untagged fence under the heading parses"

finish
