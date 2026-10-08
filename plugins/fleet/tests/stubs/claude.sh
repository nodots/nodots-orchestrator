#!/usr/bin/env bash
# claude stub for the fleet fixture tests. Records how it was invoked, then
# behaves per CLAUDE_STUB_MODE_<PACKAGE> (package id with . -> _):
#   pr       commit a file in lane, push, register a PR in the gh stub, exit 0
#   silent   print a result and exit 0 with nothing to show
#   fail     exit 3
#   blocker  write BLOCKER.md with a known Kind, exit 0
#   sleep    stay alive for CLAUDE_STUB_SLEEP seconds (default 20)
set -u
PKG="${FLEET_PACKAGE:-unknown}"
KEY="CLAUDE_STUB_MODE_${PKG//./_}"
MODE="${!KEY:-silent}"
LOG="${CLAUDE_STUB_LOG:?}"
mkdir -p "$LOG"
n=1; while [ -e "$LOG/$PKG.$n.argv" ]; do n=$((n + 1)); done
printf '%s\n' "$@" > "$LOG/$PKG.$n.argv"
{ echo "cwd=$PWD"; echo "CLAUDECODE=${CLAUDECODE-<unset>}"; echo "FLEET_WORKER_ID=${FLEET_WORKER_ID-}"; echo "FLEET_ISSUE=${FLEET_ISSUE-}"; echo "FLEET_PACKAGE=$PKG"; echo "mode=$MODE"; } > "$LOG/$PKG.$n.env"

result() { printf '{"type":"result","is_error":false,"result":"%s","session_id":"stub","total_cost_usd":0.01}\n' "$1"; }

case "$MODE" in
  pr)
    mkdir -p src && printf 'work for %s\n' "$PKG" > "src/$PKG.txt"
    git add src && git -c user.name=stub -c user.email=stub@example.invalid commit -q -m "$PKG: implement" && git push -q origin HEAD || exit 9
    branch=$(git rev-parse --abbrev-ref HEAD); sha=$(git rev-parse HEAD)
    node -e '
      const fs=require("fs"),p=process.env.GH_STUB_DIR+"/prs.json";
      const prs=JSON.parse(fs.readFileSync(p,"utf8"));
      const n=200+prs.length;
      prs.push({number:n,title:"[READY]: "+process.argv[1]+" done",body:"Closes #"+process.env.FLEET_ISSUE,state:"OPEN",headRefName:process.argv[2],headRefOid:process.argv[3],isDraft:false,url:"https://example.invalid/pr/"+n,repo:process.env.CLAUDE_STUB_TARGET});
      fs.writeFileSync(p,JSON.stringify(prs,null,2));' "$PKG" "$branch" "$sha"
    result "opened PR"; exit 0 ;;
  silent) result "did nothing"; exit 0 ;;
  fail) echo "boom" >&2; exit 3 ;;
  blocker)
    printf '# Blocker: %s\n\n- **Bucket:** scope\n- **Kind:** `human-decision`\n- **Reference:** #%s\n- **One-line ask:** widen the lane or split the package\n' "$PKG" "${FLEET_ISSUE-}" > BLOCKER.md
    result "blocked"; exit 0 ;;
  sleep) sleep "${CLAUDE_STUB_SLEEP:-20}"; result "slept"; exit 0 ;;
  *) echo "claude stub: unknown mode $MODE" >&2; exit 2 ;;
esac
