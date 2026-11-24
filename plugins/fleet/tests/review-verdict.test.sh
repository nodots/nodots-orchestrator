#!/usr/bin/env bash
# parseVerdict and findingLines (src/review.js): a verdict with prose before its
# JSON, or a finding at line 0 (the file as a whole), is judgeable; the shape
# check that stops a finding forging a stamp line is unchanged.
set -uo pipefail
cd "$(dirname "$0")"
. ./lib.sh

SRC="$(cd .. && pwd -P)/src"
assert_file "$SRC/review.js" "review.js exists"

# okof <text> -> "ok:<verdict>:<n findings>" or "bad:<error>". Text goes through the environment.
okof() { T="$1" node -e "const r=require('$SRC/review.js').parseVerdict(process.env.T);console.log(r.ok?'ok:'+r.verdict+':'+r.findings.length:'bad:'+r.error)" 2>&1; }
# fnd <line> -> a one-finding fail verdict with that line value
fnd() { printf '{"verdict":"fail","findings":[{"file":"a.js","line":%s,"claim":"c","evidence":"e"}]}' "$1"; }

V='{"verdict":"pass","findings":[{"file":"a.js","line":3,"claim":"c","evidence":"e"}]}'
FAIL2=$(fnd 2)

assert_eq "ok:pass:1" "$(okof "$V")" "plain JSON parses"
assert_eq "ok:pass:1" "$(okof "The verdict:
$V")" "prose before the JSON parses"
assert_eq "ok:pass:1" "$(okof "$V
Thanks.")" "prose after the JSON parses"
assert_eq "ok:fail:1" "$(okof "I found {a problem}.
\`\`\`json
$FAIL2
\`\`\`
Done.")" "a fenced json block is parsed over braces in prose"
assert_eq "ok:fail:1" "$(okof "\`\`\`json
{\"verdict\":\"pass\",\"findings\":[]}
\`\`\`
Revised:
\`\`\`json
$FAIL2
\`\`\`")" "the last fenced block wins"
assert_eq "ok:pass:1" "$(okof "Verdict:
\`\`\`
$V
\`\`\`")" "a bare fenced block is parsed"

assert_contains "$(okof 'no verdict here')" "bad:not JSON" "no candidate: not JSON"
assert_contains "$(okof 'text {not json} text')" "bad:not JSON" "unparseable candidate: not JSON"
assert_contains "$(okof '{"verdict":"fail","findings":[]}')" "bad:a fail with no findings" "a fail with no findings is refused"
assert_contains "$(okof '{"verdict":"pass","findings":[{"file":"a","line":1,"claim":"c"}]}')" "bad:findings[0]" "a finding missing evidence is refused"

assert_eq "ok:fail:1" "$(okof "$(fnd 0)")" "line 0 is accepted"
assert_contains "$(okof "$(fnd -1)")" "bad:findings[0]" "line -1 is refused"
assert_contains "$(okof "$(fnd 1.5)")" "bad:findings[0]" "line 1.5 is refused"

fl() { node -e "const r=require('$SRC/review.js');console.log(r.findingLines([$1]))" 2>&1; }
assert_eq "- a.js — c
  evidence: e" "$(fl '{file:"a.js",line:0,claim:"c",evidence:"e"}')" "line 0 renders without :0"
assert_eq "- a.js:7 — c
  evidence: e" "$(fl '{file:"a.js",line:7,claim:"c",evidence:"e"}')" "line 7 renders with :7"
BR=$(node -e "console.log(require('$SRC/review.js').BRIEF.join('\n'))")
assert_contains "$BR" "0 for the file as a whole" "the brief explains line 0"

finish
