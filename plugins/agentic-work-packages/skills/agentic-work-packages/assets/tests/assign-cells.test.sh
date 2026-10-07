#!/usr/bin/env bash
# Fixture test for assign-cells.sh.
#
# The rows that matter are the ones where a wrong answer hands the same slot to
# two accounts or runs a contract change beside other work: assigned-but-
# unstarted packages count as load, a double-owned package is flagged rather
# than guessed at, and a contract-change drains the fleet instead of starving.
set -uo pipefail
cd "$(dirname "$0")"
. ./lib.sh

SCRIPT="$(cd ../scripts && pwd -P)/assign-cells.sh"
assert_file "$SCRIPT" "assign-cells.sh exists"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

row() { printf '%s' "$OUT" | grep -E "^#$1 " || true; }

# --- balance across two workers ---------------------------------------------
# a carries one active package, b carries none, so the first candidate goes to
# b. The second is a tie at 1/1 and goes to a, the first listed.
cat > "$TMP/balance.json" <<'JSON'
{ "repo": "example/host", "issues": [
  { "number": 1, "title": "epic", "state": "OPEN", "labels": ["epic"] },
  { "number": 10, "title": "M1.1 active", "state": "OPEN", "labels": ["cell:active", "worker:a"] },
  { "number": 11, "title": "M1.2 next", "state": "OPEN", "labels": ["agent-ready", "cell:queued"] },
  { "number": 12, "title": "M1.3 after", "state": "OPEN", "labels": ["agent-ready", "cell:queued"] },
  { "number": 13, "title": "M1.4 not ready", "state": "OPEN", "labels": ["cell:queued"] },
  { "number": 14, "title": "M0.9 done", "state": "CLOSED", "labels": ["agent-ready", "cell:queued"] }
] }
JSON
OUT=$(bash "$SCRIPT" --state "$TMP/balance.json" --workers a,b 2>"$TMP/err"); EXIT=$?
assert_eq 0 "$EXIT" "a dry run over a fixture exits 0"
assert_empty "$(cat "$TMP/err")" "a dry run over a fixture writes nothing to stderr"
assert_contains "$(row 11)" "worker:b" "the first candidate goes to the idle worker"
assert_contains "$(row 12)" "worker:a" "a tie goes to the worker listed first"
assert_empty "$(row 13)" "a queued package that is not agent-ready is not a candidate"
assert_empty "$(row 14)" "a closed package is not a candidate"
assert_contains "$OUT" "Dry run" "the default run says it wrote nothing"
assert_not_contains "$OUT" "label(s) written" "the default run does not claim a write"
assert_contains "$OUT" "in flight 3/4" "the closing line reports the fleet after assignment"

# --- the WIP cap -------------------------------------------------------------
OUT=$(bash "$SCRIPT" --state "$TMP/balance.json" --workers a,b --wip-cap 2 2>/dev/null)
assert_contains "$(row 11)" "worker:b" "under the cap the candidate is assigned"
assert_contains "$(row 12)" "hold" "at the cap the next candidate is held"
assert_contains "$(row 12)" "WIP cap" "the hold names the cap"

# --- assigned but unstarted counts as load ----------------------------------
# #20 is cell:queued and already labeled worker:a. Without counting it, the cap
# of 1 would look empty and a second slot would be handed out next cycle.
cat > "$TMP/unstarted.json" <<'JSON'
{ "repo": "example/host", "issues": [
  { "number": 20, "title": "M2.1 assigned", "state": "OPEN", "labels": ["agent-ready", "cell:queued", "worker:a"] },
  { "number": 21, "title": "M2.2 next", "state": "OPEN", "labels": ["agent-ready", "cell:queued"] }
] }
JSON
OUT=$(bash "$SCRIPT" --state "$TMP/unstarted.json" --workers a,b --wip-cap 1 2>/dev/null)
assert_contains "$(row 21)" "hold" "an assigned, unstarted package occupies a slot"
assert_empty "$(row 20)" "an already-assigned package is not reassigned"

# --- an active package with no worker label still counts --------------------
cat > "$TMP/unlabeled.json" <<'JSON'
{ "repo": "example/host", "issues": [
  { "number": 30, "title": "M3.1 pre-existing", "state": "OPEN", "labels": ["cell:active"] },
  { "number": 31, "title": "M3.2 next", "state": "OPEN", "labels": ["agent-ready", "cell:queued"] }
] }
JSON
OUT=$(bash "$SCRIPT" --state "$TMP/unlabeled.json" --workers a,b --wip-cap 1 2>/dev/null)
assert_contains "$(row 31)" "hold" "an active package with no worker label still counts toward the cap"

# --- a package with two owners is flagged, not guessed at --------------------
cat > "$TMP/double.json" <<'JSON'
{ "repo": "example/host", "issues": [
  { "number": 40, "title": "M4.1 two owners", "state": "OPEN", "labels": ["agent-ready", "cell:queued", "worker:a", "worker:b"] },
  { "number": 41, "title": "M4.2 clean", "state": "OPEN", "labels": ["agent-ready", "cell:queued"] }
] }
JSON
OUT=$(bash "$SCRIPT" --state "$TMP/double.json" --workers a,b 2>/dev/null)
assert_contains "$(row 40)" "one owner only" "a double-owned package is flagged"
assert_not_contains "$(row 40)" "assign ->" "a double-owned package is not reassigned"
assert_contains "$(row 41)" "worker:a" "the double-owned package adds no load, so the next goes to a"

# --- a worker label outside --workers is surfaced ---------------------------
cat > "$TMP/unlisted.json" <<'JSON'
{ "repo": "example/host", "issues": [
  { "number": 50, "title": "M5.1 someone else", "state": "OPEN", "labels": ["cell:active", "worker:c"] },
  { "number": 51, "title": "M5.2 next", "state": "OPEN", "labels": ["agent-ready", "cell:queued"] }
] }
JSON
OUT=$(bash "$SCRIPT" --state "$TMP/unlisted.json" --workers a,b --wip-cap 1 2>/dev/null)
assert_contains "$(row 50)" "not in --workers" "an unlisted worker label is named"
assert_contains "$(row 51)" "hold" "an unlisted worker's package still counts toward the cap"

# --- contract changes never run beside other work ---------------------------
cat > "$TMP/contract-flight.json" <<'JSON'
{ "repo": "example/host", "issues": [
  { "number": 60, "title": "C1.1 contract", "state": "OPEN", "labels": ["cell:active", "cell:contract-change", "worker:a"] },
  { "number": 61, "title": "C1.2 next", "state": "OPEN", "labels": ["agent-ready", "cell:queued"] }
] }
JSON
OUT=$(bash "$SCRIPT" --state "$TMP/contract-flight.json" --workers a,b 2>/dev/null)
assert_contains "$(row 61)" "contract-change #60 in flight" "nothing is assigned while a contract change is in flight"

cat > "$TMP/contract-drain.json" <<'JSON'
{ "repo": "example/host", "issues": [
  { "number": 70, "title": "D1.1 active", "state": "OPEN", "labels": ["cell:active", "worker:a"] },
  { "number": 71, "title": "D1.2 contract", "state": "OPEN", "labels": ["agent-ready", "cell:queued", "cell:contract-change"] },
  { "number": 72, "title": "D1.3 later", "state": "OPEN", "labels": ["agent-ready", "cell:queued"] }
] }
JSON
OUT=$(bash "$SCRIPT" --state "$TMP/contract-drain.json" --workers a,b 2>/dev/null)
assert_contains "$(row 71)" "waits for an empty fleet" "a contract change is held while the fleet is busy"
assert_contains "$(row 72)" "draining" "later packages are held so the fleet drains and the contract change is not starved"
assert_not_contains "$OUT" "assign ->" "nothing is assigned while draining"

cat > "$TMP/contract-empty.json" <<'JSON'
{ "repo": "example/host", "issues": [
  { "number": 80, "title": "E1.1 contract", "state": "OPEN", "labels": ["agent-ready", "cell:queued", "cell:contract-change"] },
  { "number": 81, "title": "E1.2 later", "state": "OPEN", "labels": ["agent-ready", "cell:queued"] }
] }
JSON
OUT=$(bash "$SCRIPT" --state "$TMP/contract-empty.json" --workers a,b 2>/dev/null)
assert_contains "$(row 80)" "assign" "a contract change goes out when the fleet is empty"
assert_contains "$(row 81)" "nothing runs beside it" "nothing is assigned beside a contract change in the same cycle"

# --- usage errors fail loudly ------------------------------------------------
OUT=$(bash "$SCRIPT" --state "$TMP/balance.json" 2>&1); EXIT=$?
assert_ne 0 "$EXIT" "--workers is required"
assert_contains "$OUT" "--workers is required" "the missing --workers is named"

OUT=$(bash "$SCRIPT" --workers a,b 2>&1); EXIT=$?
assert_ne 0 "$EXIT" "no --state and no --repo is an error"
assert_contains "$OUT" "required" "the usage error says what is required"

OUT=$(bash "$SCRIPT" --state "$TMP/balance.json" --workers 'a;rm' 2>&1); EXIT=$?
assert_ne 0 "$EXIT" "a worker id with shell metacharacters is refused"
assert_contains "$OUT" "invalid worker id" "the bad id is named"

OUT=$(bash "$SCRIPT" --state "$TMP/balance.json" --workers a,b --wip-cap 0 2>&1); EXIT=$?
assert_ne 0 "$EXIT" "a zero WIP cap is refused"

OUT=$(bash "$SCRIPT" --state "$TMP/nope.json" --workers a,b 2>&1); EXIT=$?
assert_ne 0 "$EXIT" "a missing state file is an error"
assert_contains "$OUT" "no such state file" "the missing state file is named"

OUT=$(bash "$SCRIPT" --state "$TMP/balance.json" --workers a,b --apply 2>&1); EXIT=$?
assert_ne 0 "$EXIT" "--apply over a bare fixture refuses"
assert_contains "$OUT" "--apply needs --repo" "the refusal names the missing --repo"

# --- the gh collector and --apply, against a stub ---------------------------
STUB="$TMP/stub"
mkdir -p "$STUB"
cat > "$STUB/gh" <<'GH'
#!/usr/bin/env bash
# Minimal gh stub. Records every call and answers issue list from a fixture.
printf '%s\n' "$*" >> "$STUB_CALLS"
case "$1 $2" in
  "issue list")
    cat <<'JSON'
[
  {"number": 90, "title": "G1.1 active", "state": "OPEN",
   "labels": [{"name": "cell:active"}, {"name": "worker:a"}]},
  {"number": 91, "title": "G1.2 next", "state": "OPEN",
   "labels": [{"name": "agent-ready"}, {"name": "cell:queued"}]}
]
JSON
    ;;
  "issue edit") [ "${STUB_FAIL_EDIT:-0}" = "1" ] && exit 1; exit 0 ;;
  *) exit 1 ;;
esac
GH
chmod +x "$STUB/gh"
export STUB_CALLS="$TMP/gh-calls.txt"
: > "$STUB_CALLS"

OUT=$(GH_BIN="$STUB/gh" bash "$SCRIPT" --repo example/host --workers a,b 2>"$TMP/err2"); EXIT=$?
assert_eq 0 "$EXIT" "the collector runs end to end against a stub gh"
calls=$(cat "$STUB_CALLS")
assert_contains "$calls" "--state open" "the collector reads open issues, the only ones that carry load"
assert_not_contains "$calls" "issue edit" "a dry run never calls issue edit"
assert_contains "$(row 91)" "worker:b" "live state goes through the same derivation"

: > "$STUB_CALLS"
OUT=$(GH_BIN="$STUB/gh" bash "$SCRIPT" --repo example/host --workers a,b --apply 2>&1); EXIT=$?
assert_eq 0 "$EXIT" "--apply exits 0 when every label lands"
calls=$(cat "$STUB_CALLS")
assert_contains "$calls" "issue edit 91 --repo example/host --add-label worker:b" "--apply adds exactly the derived label"
assert_contains "$OUT" "1 label(s) written, 0 failed" "--apply reports what it wrote"

OUT=$(STUB_FAIL_EDIT=1 GH_BIN="$STUB/gh" bash "$SCRIPT" --repo example/host --workers a,b --apply 2>&1); EXIT=$?
assert_ne 0 "$EXIT" "a failed label write fails the run rather than reporting success"
assert_contains "$OUT" "failed to label #91" "the failed package is named"
assert_contains "$OUT" "0 label(s) written, 1 failed" "the tally does not count the failed write"

# --- a truncated collection must fail, never assign from partial state -------
cat > "$STUB/gh" <<'GH'
#!/usr/bin/env bash
case "$1 $2" in
  "issue list")
    lim=1000
    for a in "$@"; do [ "$prev" = "--limit" ] && lim="$a"; prev="$a"; done
    printf '['
    i=1
    while [ "$i" -le "$lim" ]; do
      [ "$i" -gt 1 ] && printf ','
      printf '{"number":%d,"title":"M%d.1 pkg","state":"OPEN","labels":[{"name":"cell:queued"}]}' "$i" "$i"
      i=$((i + 1))
    done
    printf ']'
    ;;
  *) echo '[]' ;;
esac
GH
chmod +x "$STUB/gh"
OUT=$(ASSIGN_CELLS_PAGE_LIMIT=5 GH_BIN="$STUB/gh" bash "$SCRIPT" --repo example/host --workers a,b 2>&1); EXIT=$?
assert_ne 0 "$EXIT" "a collection that fills the page limit fails rather than assigning from partial state"
assert_contains "$OUT" "truncat" "the truncation is named in the failure"

finish
