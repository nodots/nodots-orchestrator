#!/usr/bin/env bash
# Fixture test for the approvalEnforcement setting (G1.3, decision D1):
# default off, a PR with no approval is not blocked when off, and the same PR
# is blocked by the named mechanism when on. This repo never turns it on.
set -uo pipefail
cd "$(dirname "$0")"
. ../../plugins/fleet/tests/lib.sh

ROOT="$(cd ../.. && pwd -P)"
SRC="$ROOT/plugins/fleet/src/config.js"
EXAMPLE="$ROOT/plugins/fleet/fleet.config.example.json"
assert_file "$SRC" "config.js exists"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/plugins/agentic-work-packages/.claude-plugin"
printf '{"name":"x"}' > "$TMP/plugins/agentic-work-packages/.claude-plugin/plugin.json"

js() { node -e "const c=require('$SRC'); $1"; }
BASE="{repo:'acme/host',epic:1,targets:[{repo:'api',localPath:'./api'}],workers:{a:{mode:'local'}},pluginRoot:'$TMP/plugins/agentic-work-packages'}"

# Fixture PR: open, no human approval.
PR="{number:7,approvals:[]}"

assert_eq "off" "$(js "console.log(c.validate($BASE,'$TMP').approvalEnforcement)")" "default is off"
assert_eq "off" "$(js "console.log(c.DEFAULTS.approvalEnforcement)")" "DEFAULTS names off"
assert_eq "off" "$(node -e "console.log(require('$EXAMPLE').approvalEnforcement)")" "the example config ships off"

assert_eq "false" "$(js "const v=c.validate($BASE,'$TMP'); console.log(c.approvalGate(v,$PR).blocked)")" "off: a PR with no approval is not blocked"

for m in branch-protection ruleset; do
  assert_eq "true" "$(js "const v=c.validate({...$BASE,approvalEnforcement:'$m'},'$TMP'); console.log(c.approvalGate(v,$PR).blocked)")" "$m: the same PR is blocked"
  assert_eq "$m" "$(js "const v=c.validate({...$BASE,approvalEnforcement:'$m'},'$TMP'); console.log(c.approvalGate(v,$PR).mechanism)")" "$m: the block names its mechanism"
  assert_eq "false" "$(js "const v=c.validate({...$BASE,approvalEnforcement:'$m'},'$TMP'); console.log(c.approvalGate(v,{number:7,approvals:[{state:'APPROVED',author:'h'}]}).blocked)")" "$m: a PR with a human approval is not blocked"
  assert_eq "1" "$(js "const v=c.validate({...$BASE,approvalEnforcement:'$m'},'$TMP'); console.log(JSON.stringify(c.approvalPayload(v)).match(/required_approving_review_count\"?:1|\"required_approving_review_count\":1/g).length)")" "$m: the payload requires one approving review"
done

assert_eq "ECONFIG" "$(js "try{c.validate({...$BASE,approvalEnforcement:'on'},'$TMP');console.log('accepted')}catch(e){console.log(e.code)}")" "an unknown value is rejected"
assert_eq "null" "$(js "const v=c.validate($BASE,'$TMP'); console.log(c.approvalPayload(v))")" "off: no payload"

# Nothing in this repository turns enforcement on.
N=$(cd "$ROOT" && git grep --untracked -n -E '"approvalEnforcement"\s*:\s*"(branch-protection|ruleset)"' -- ':!*.test.sh' ':!*.md' | wc -l | tr -d ' ')
assert_eq "0" "$N" "no tracked config turns approval enforcement on"

finish
