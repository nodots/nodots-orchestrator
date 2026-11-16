#!/usr/bin/env bash
# reviewer stub for the fleet review-stage test. Invoked as a configured
# reviewer argv: reviewer.sh <prompt file> <worktree> <verdict file>.
# Records how it was invoked in REVIEWER_STUB_LOG, then behaves per
# REVIEWER_STUB_VERDICT_<pr> (the PR fleet sets in FLEET_REVIEW_PR), else
# REVIEWER_STUB_VERDICT, else pass:
#   pass     write {"verdict":"pass","findings":[...]} and exit 0
#   fail     write {"verdict":"fail","findings":[...]} and exit 0
#   invalid  write text that is not JSON
#   none     write nothing
#   write    change a file in the worktree, then write a pass verdict
#   commit   move the worktree's HEAD with an empty commit, then write a pass verdict
#   sleep    stay alive until the file REVIEWER_STUB_GATE exists (up to 60 s),
#            or for REVIEWER_STUB_SLEEP seconds, then write a pass verdict
set -u
PROMPT="$1"; WT="$2"; OUT="$3"
LOG="${REVIEWER_STUB_LOG:?}"
mkdir -p "$LOG"
PR="${FLEET_REVIEW_PR:-unknown}"
KEY="REVIEWER_STUB_VERDICT_${PR}"
MODE="${!KEY:-${REVIEWER_STUB_VERDICT:-pass}}"
n=1; while [ -e "$LOG/$PR.$n.argv" ]; do n=$((n + 1)); done
printf '%s\n' "$@" > "$LOG/$PR.$n.argv"
{ echo "cwd=$PWD"; echo "head=$(git -C "$WT" rev-parse HEAD 2>/dev/null)"; echo "FLEET_REVIEWER=${FLEET_REVIEWER-}"; echo "FLEET_REVIEW_REPO=${FLEET_REVIEW_REPO-}"; echo "mode=$MODE"; } > "$LOG/$PR.$n.env"
cp "$PROMPT" "$LOG/$PR.$n.prompt"

pass() { printf '{"verdict":"pass","findings":[{"file":"src/x.txt","line":1,"claim":"checked the content","evidence":"line 1 reads as the issue asks"}]}\n' > "$OUT"; }
case "$MODE" in
  pass) pass ;;
  fail) printf '{"verdict":"fail","findings":[{"file":"src/x.txt","line":3,"claim":"the guard is inverted","evidence":"an empty list passes"},{"file":"src/y.txt","line":9,"claim":"no test fails without the change","evidence":"the test asserts true"}]}\n' > "$OUT" ;;
  invalid) printf 'looks fine to me\n' > "$OUT" ;;
  none) : ;;
  write) printf 'reviewer was here\n' >> "$WT/README.md"; pass ;;
  commit) git -C "$WT" -c user.name=stub -c user.email=stub@example.invalid commit -q --allow-empty -m "reviewer commit"; pass ;;
  sleep)
    if [ -n "${REVIEWER_STUB_GATE:-}" ]; then i=0; until [ -e "$REVIEWER_STUB_GATE" ] || [ $i -ge 120 ]; do sleep 0.5; i=$((i + 1)); done
    else sleep "${REVIEWER_STUB_SLEEP:-20}"; fi
    pass ;;
  *) echo "reviewer stub: unknown mode $MODE" >&2; exit 2 ;;
esac
exit 0
