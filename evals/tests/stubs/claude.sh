#!/usr/bin/env bash
# claude stub for scripts/tests/evals-runner.test.sh. Records its argv, then
# behaves per tokens found in the prompt (the argument after -p):
#   stub:cost=N      print a result whose total_cost_usd is N
#   stub:nocost      print a result with no cost field
#   stub:write=FILE  create FILE in the working directory
#   stub:exit3       exit 3 after printing
set -u
LOG="${EVAL_STUB_LOG:?}"
mkdir -p "$LOG"
n=1; while [ -e "$LOG/argv.$n" ]; do n=$((n + 1)); done
printf '%s\n' "$@" > "$LOG/argv.$n"

prompt=""
while [ $# -gt 0 ]; do
  if [ "$1" = "-p" ]; then prompt="${2-}"; break; fi
  shift
done

for tok in $prompt; do
  case "$tok" in
    stub:write=*) : > "${tok#stub:write=}" ;;
  esac
done

cost=""
for tok in $prompt; do
  case "$tok" in stub:cost=*) cost="${tok#stub:cost=}" ;; esac
done

case " $prompt " in
  *" stub:nocost "*) printf '{"type":"result","is_error":false,"result":"done"}\n' ;;
  *) if [ -n "$cost" ]; then
       printf '{"type":"result","is_error":false,"result":"done","total_cost_usd":%s}\n' "$cost"
     else
       printf '{"type":"result","is_error":false,"result":"done","total_cost_usd":0.01}\n'
     fi ;;
esac

case " $prompt " in *" stub:exit3 "*) exit 3 ;; esac
exit 0
