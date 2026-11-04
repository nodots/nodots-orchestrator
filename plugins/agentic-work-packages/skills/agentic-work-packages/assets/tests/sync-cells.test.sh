#!/usr/bin/env bash
# Fixture test for sync-cells.sh (N-3), and for the VERIFIED stamp parser the
# evidence rule depends on (N-2).
#
# Every precedence rule gets a row, and the stale-sha row is the one that
# matters: a stamp naming a sha the PR has since moved past is evidence about a
# tree nobody is reviewing, and must not promote the package to awaiting-review.
set -uo pipefail
cd "$(dirname "$0")"
. ./lib.sh

SCRIPT="$(cd ../scripts && pwd -P)/sync-cells.sh"
assert_file "$SCRIPT" "sync-cells.sh exists"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

SHA_HEAD=1111111111111111111111111111111111111111
SHA_OLD=2222222222222222222222222222222222222222

cat > "$TMP/state.json" <<JSON
{
  "repo": "example/host",
  "target": "example/code",
  "issues": [
    {
      "number": 101, "title": "M0.1 frozen protocol", "label": "cell:awaiting-review",
      "branch": "feat/m0-1", "branchExists": true, "blockerOnBranch": false,
      "pr": { "number": 201, "state": "MERGED", "headSha": "$SHA_HEAD", "comments": [] }
    },
    {
      "number": 102, "title": "M1.1 session store", "label": "cell:active",
      "branch": "feat/m1-1", "branchExists": true, "blockerOnBranch": false,
      "pr": { "number": 202, "state": "OPEN", "headSha": "$SHA_HEAD",
              "comments": ["looks good", "VERIFIED: unit+e2e @ $SHA_HEAD\n\nnpm test\n40 passed, 0 skipped"] }
    },
    {
      "number": 103, "title": "M1.2 relay", "label": "cell:active",
      "branch": "feat/m1-2", "branchExists": true, "blockerOnBranch": false,
      "pr": { "number": 203, "state": "OPEN", "headSha": "$SHA_HEAD",
              "comments": ["VERIFIED: unit @ $SHA_OLD\n\nnpm test\n40 passed"] }
    },
    {
      "number": 104, "title": "M1.3 validation", "label": "cell:active",
      "branch": "feat/m1-3", "branchExists": true, "blockerOnBranch": true,
      "pr": null
    },
    {
      "number": 105, "title": "M1.4 clock", "label": "cell:queued",
      "branch": "feat/m1-4", "branchExists": true, "blockerOnBranch": false,
      "pr": null
    },
    {
      "number": 106, "title": "M2.1 lobby", "label": "cell:queued",
      "branch": null, "branchExists": false, "blockerOnBranch": false,
      "pr": null
    },
    {
      "number": 107, "title": "M2.2 sync", "label": "cell:blocked",
      "branch": "feat/m2-2", "branchExists": true, "blockerOnBranch": true,
      "pr": { "number": 207, "state": "OPEN", "headSha": "$SHA_HEAD", "comments": [] }
    },
    {
      "number": 108, "title": "M2.3 stale-close", "label": "cell:active",
      "branch": "feat/m2-3", "branchExists": true, "blockerOnBranch": false,
      "pr": { "number": 208, "state": "CLOSED", "headSha": "$SHA_HEAD", "comments": [] }
    }
  ]
}
JSON

OUT=$(bash "$SCRIPT" --state "$TMP/state.json" 2>"$TMP/err")
EXIT=$?
assert_eq 0 "$EXIT" "a dry run over a fixture exits 0"
assert_empty "$(cat "$TMP/err")" "a dry run over a fixture writes nothing to stderr"

row() { printf '%s' "$OUT" | grep -E "^#$1 " || true; }

assert_contains "$(row 101)" "cell:merged"          "merged PR wins over every other rule"
assert_contains "$(row 102)" "cell:awaiting-review" "open PR with a current stamp is awaiting review"
assert_contains "$(row 102)" "unit+e2e"             "the derivation names the suite from the stamp"
assert_contains "$(row 103)" "unchanged"            "a stamp naming a superseded sha does not promote"
assert_not_contains "$(row 103)" "awaiting-review"  "a stale stamp is not evidence for this head"
assert_contains "$(row 104)" "cell:blocked"         "BLOCKER.md on the branch blocks"
assert_contains "$(row 105)" "cell:active"          "a branch with no PR is active"
assert_contains "$(row 106)" "unchanged"            "no branch and no PR leaves the label alone"
assert_contains "$(row 107)" "cell:blocked"         "an open PR without a stamp yields to a blocker"
assert_contains "$(row 108)" "cell:active"          "a closed, unmerged PR falls through to the branch rule"

assert_contains "$OUT" "Dry run" "the default run says it wrote nothing"
assert_not_contains "$OUT" "label(s) written" "the default run does not claim a write"

# The stale-sha row is N-2's acceptance: state it once more, on its own.
stale=$(row 103)
assert_contains "$stale" "cell:active" "the stale-stamp package keeps the label it had"

# --emit-state writes out exactly the state the derivation ran over, and the
# row format a driving runtime parses for its report is pinned here.
OUT_E=$(bash "$SCRIPT" --state "$TMP/state.json" --emit-state "$TMP/emitted.json" 2>&1); EXIT_E=$?
assert_eq 0 "$EXIT_E" "--emit-state over a fixture exits 0"
assert_file "$TMP/emitted.json" "--emit-state writes the file"
if cmp -s "$TMP/state.json" "$TMP/emitted.json"; then
  _pass "--emit-state over --state emits the same bytes"
else
  _fail "--emit-state over --state emits the same bytes" "files differ"
fi
assert_file "$TMP/emitted.json" "no .tmp residue is left beside the emitted file"
[ -e "$TMP/emitted.json.tmp" ] && _fail "no .tmp residue is left beside the emitted file" "emitted.json.tmp exists"
r101=$(printf '%s' "$OUT_E" | grep -E '^#101 ' || true)
case "$r101" in
  "#101  cell:awaiting-review -> cell:merged   (PR #201 merged)") _pass "a change row has the pinned shape: '#N  from -> to   (why)'" ;;
  *) _fail "a change row has the pinned shape: '#N  from -> to   (why)'" "got [$r101]" ;;
esac
r106=$(printf '%s' "$OUT_E" | grep -E '^#106 ' || true)
case "$r106" in
  "#106  cell:queued   (unchanged: no rule matched)") _pass "an unchanged row has the pinned shape: '#N  label   (unchanged: why)'" ;;
  *) _fail "an unchanged row has the pinned shape: '#N  label   (unchanged: why)'" "got [$r106]" ;;
esac

# --apply without --repo must refuse rather than half-run.
OUT2=$(bash "$SCRIPT" --state "$TMP/state.json" --apply 2>&1)
assert_contains "$OUT2" "--apply needs --repo" "--apply over a bare fixture refuses"

# An unreadable state file fails loudly rather than reporting an empty plan.
OUT3=$(bash "$SCRIPT" --state "$TMP/nope.json" 2>&1); EXIT3=$?
assert_ne 0 "$EXIT3" "a missing state file is an error"
assert_contains "$OUT3" "no such state file" "the missing state file is named"

# Neither --state nor --repo is a usage error, not a silent no-op.
OUT4=$(bash "$SCRIPT" 2>&1); EXIT4=$?
assert_ne 0 "$EXIT4" "no arguments is an error"
assert_contains "$OUT4" "required" "the usage error says what is required"


# --- the gh collector itself, against a stub -------------------------------
# Regression for a defect the state-file fixtures structurally could not catch:
# the collector queried `gh issue list --state open`, but a package whose PR
# merged with "Closes #N" has had its issue CLOSED by GitHub. That package is
# precisely the one that must become cell:merged, and it was invisible.
STUB="$TMP/stub"
mkdir -p "$STUB"
cat > "$STUB/gh" <<'GH'
#!/usr/bin/env bash
# Minimal gh stub. Records the issue-list arguments so the test can assert on
# them, and answers each query from a canned fixture.
case "$1 $2" in
  "issue list")
    printf '%s
' "$*" >> "$STUB_CALLS"
    # The merged package's issue is CLOSED, as GitHub leaves it.
    cat <<'JSON'
[
  {"number": 1, "title": "M0.1 Freeze protocol", "state": "CLOSED",
   "labels": [{"name": "cell:queued"}]},
  {"number": 2, "title": "M1.1 Session store", "state": "OPEN",
   "labels": [{"name": "cell:queued"}]}
]
JSON
    ;;
  "pr list")
    cat <<'JSON'
[
  {"number": 7, "title": "[READY]: M0.1", "body": "Closes #1", "state": "MERGED",
   "headRefName": "feat/M0.1-freeze", "headRefOid": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},
  {"number": 8, "title": "[READY]: M1.1", "body": "Closes #2", "state": "OPEN",
   "headRefName": "feat/M1.1-store", "headRefOid": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}
]
JSON
    ;;
  "api repos"*|"api "*)
    case "$*" in
      *"/branches"*) printf '%s\n' development feat/M0.1-freeze feat/M1.1-store ;;
      *"BLOCKER.md"*) exit 1 ;;                      # no blocker on any branch
      *"/comments"*) : ;;                             # no comments, so no lines
      *) echo '[]' ;;
    esac
    ;;
  *) exit 1 ;;
esac
GH
chmod +x "$STUB/gh"
export STUB_CALLS="$TMP/gh-calls.txt"
: > "$STUB_CALLS"

OUT=$(GH_BIN="$STUB/gh" STUB_CALLS="$STUB_CALLS" bash "$SCRIPT" --repo example/host 2>"$TMP/err2")
EXIT=$?
assert_eq 0 "$EXIT" "the collector runs end to end against a stub gh"

calls=$(cat "$STUB_CALLS")
assert_contains "$calls" "--state all" "the issue query asks for every issue, not just open ones"
assert_not_contains "$calls" "--state open" "the issue query does not filter to open issues"

assert_contains "$OUT" "cell:merged" "a merged PR whose issue GitHub closed still becomes cell:merged"
row1=$(printf '%s' "$OUT" | grep -E '^#1 ' || true)
assert_contains "$row1" "cell:merged" "issue #1 (closed by the merge) is relabelled, not skipped"
row2=$(printf '%s' "$OUT" | grep -E '^#2 ' || true)
assert_contains "$row2" "unchanged" "issue #2 (open PR, no current stamp) is left alone"
assert_not_contains "$row2" "awaiting-review" "an open PR without evidence is never promoted to review"

# Rows are reported in issue order, so a coordinator can read the queue.
first=$(printf '%s' "$OUT" | grep -E '^#' | head -1)
assert_contains "$first" "#1" "rows are listed in issue order"

# --- branch matching must survive real-world branch names -------------------
# The numbering rules require the package id in the branch name, but they do
# not require the branch to preserve the id's case or its dot. Real branches
# are lower-case and hyphenated: feat/m1-3-validation for package M1.3.
cat > "$STUB/gh" <<'GH'
#!/usr/bin/env bash
case "$1 $2" in
  "issue list")
    cat <<'JSON'
[
  {"number": 11, "title": "M1.3 Server-side validation", "state": "OPEN",
   "labels": [{"name": "cell:queued"}]},
  {"number": 12, "title": "M1.30 Later package", "state": "OPEN",
   "labels": [{"name": "cell:queued"}]}
]
JSON
    ;;
  "pr list") echo '[]' ;;
  "api repos"*|"api "*)
    case "$*" in
      *"/branches"*) printf '%s\n' development feat/m1-3-validation ;;
      *"BLOCKER.md"*) exit 1 ;;
      *) echo '[]' ;;
    esac
    ;;
  *) exit 1 ;;
esac
GH
chmod +x "$STUB/gh"
OUT=$(GH_BIN="$STUB/gh" bash "$SCRIPT" --repo example/host 2>/dev/null)
r11=$(printf '%s' "$OUT" | grep -E '^#11 ' || true)
r12=$(printf '%s' "$OUT" | grep -E '^#12 ' || true)
assert_contains "$r11" "cell:active" "a lower-case hyphenated branch matches its package id (M1.3 -> feat/m1-3-...)"
assert_contains "$r12" "unchanged"   "M1.30 does not steal M1.3's branch (no unbounded substring match)"

# --- BLOCKER.md in the cell directory counts ---------------------------------
# The hooks and the worker contract let a worker write BLOCKER.md at the repo
# root or in .agentic/cells/<branch>/. A sync that looked only at the root
# reported such a package cell:active, and the coordinator never saw the stop.
cat > "$STUB/gh" <<'GH'
#!/usr/bin/env bash
case "$1 $2" in
  "issue list")
    cat <<'JSON'
[
  {"number": 31, "title": "N1.1 Cell-dir blocker", "state": "OPEN", "labels": [{"name": "cell:active"}]},
  {"number": 32, "title": "N1.2 Root blocker", "state": "OPEN", "labels": [{"name": "cell:active"}]},
  {"number": 33, "title": "N1.3 No blocker", "state": "OPEN", "labels": [{"name": "cell:active"}]}
]
JSON
    ;;
  "pr list") echo '[]' ;;
  "api "*)
    case "$*" in
      *"/branches"*) printf '%s\n' development feat/n1-1-x feat/n1-2-y feat/n1-3-z ;;
      *"contents/.agentic/cells/feat/n1-1-x/BLOCKER.md"*) exit 0 ;;
      *"contents/BLOCKER.md?ref=feat/n1-2-y"*) exit 0 ;;
      *"BLOCKER.md"*) exit 1 ;;
      *) : ;;
    esac
    ;;
  *) exit 1 ;;
esac
GH
chmod +x "$STUB/gh"
OUT=$(GH_BIN="$STUB/gh" bash "$SCRIPT" --repo example/host 2>/dev/null)
assert_contains "$(printf '%s' "$OUT" | grep -E '^#31 ' || true)" "cell:blocked" "a BLOCKER.md in .agentic/cells/<branch>/ blocks the package"
assert_contains "$(printf '%s' "$OUT" | grep -E '^#32 ' || true)" "cell:blocked" "a BLOCKER.md at the repo root still blocks the package"
assert_contains "$(printf '%s' "$OUT" | grep -E '^#33 ' || true)" "unchanged" "no BLOCKER.md anywhere leaves an active package alone"

# --- a PR that merely mentions an issue is not that issue's PR -------------
# Regression from a host repo: T5.1c's PR body said "skips two routes (T5.1d,
# #363, must delete the list)", and sync relabelled #363 cell:merged on the
# strength of T5.1c's merge. Only a title reference or a closing keyword counts.
cat > "$STUB/gh" <<'GH'
#!/usr/bin/env bash
case "$1 $2" in
  "issue list")
    cat <<'JSON'
[
  {"number": 41, "title": "P1.1 Contracts", "state": "CLOSED", "labels": [{"name": "cell:active"}]},
  {"number": 42, "title": "P1.2 Wire it", "state": "OPEN", "labels": [{"name": "cell:queued"}]},
  {"number": 43, "title": "P1.3 Fixed by keyword", "state": "CLOSED", "labels": [{"name": "cell:active"}]},
  {"number": 44, "title": "P1.4 In the title", "state": "CLOSED", "labels": [{"name": "cell:active"}]}
]
JSON
    ;;
  "pr list")
    cat <<'JSON'
[
  {"number": 51, "title": "[READY]: P1.1 contracts", "body": "Closes #41\n\nNotes: skips two routes (P1.2, #42, must delete the list).", "state": "MERGED", "headRefName": "feat/p1-1", "headRefOid": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},
  {"number": 53, "title": "[READY]: fix the thing", "body": "Fixes: acme/host#43", "state": "MERGED", "headRefName": "feat/p1-3", "headRefOid": "cccccccccccccccccccccccccccccccccccccccc"},
  {"number": 54, "title": "[READY]: P1.4 (#44)", "body": "no keyword here", "state": "MERGED", "headRefName": "feat/p1-4", "headRefOid": "dddddddddddddddddddddddddddddddddddddddd"}
]
JSON
    ;;
  "api "*)
    case "$*" in
      *"/branches"*) printf '%s\n' development feat/p1-1 feat/p1-3 feat/p1-4 ;;
      *"BLOCKER.md"*) exit 1 ;;
      *) : ;;
    esac
    ;;
  *) exit 1 ;;
esac
GH
chmod +x "$STUB/gh"
OUT=$(GH_BIN="$STUB/gh" bash "$SCRIPT" --repo acme/host 2>/dev/null)
assert_contains "$(printf '%s' "$OUT" | grep -E '^#41 ' || true)" "cell:merged" "Closes #41 in the body claims the PR"
assert_contains "$(printf '%s' "$OUT" | grep -E '^#42 ' || true)" "unchanged"   "a bare mention of #42 in another PR's body does not claim it"
assert_not_contains "$(printf '%s' "$OUT" | grep -E '^#42 ' || true)" "merged" "the mentioned package is not relabelled merged"
assert_contains "$(printf '%s' "$OUT" | grep -E '^#43 ' || true)" "cell:merged" "Fixes: owner/repo#43 claims the PR"
assert_contains "$(printf '%s' "$OUT" | grep -E '^#44 ' || true)" "cell:merged" "#44 in the PR title claims the PR"

# --- an open [VERIFY] PR waiting on the verifier is awaiting-lab ------------
# A [VERIFY]: PR with no current stamp is queued for the lab, not active: a
# worker still writing code and a PR waiting for the verifier look identical
# under the branch rule, and the queue was invisible. A stale stamp does not
# count, and a [VERIFY] PR with a blocker still reads awaiting-lab, because the
# precedence puts the lab queue above blocked.
cat > "$TMP/state-verify.json" <<JSON
{
  "repo": "example/host",
  "targets": ["example/host"],
  "issues": [
    { "number": 201, "title": "V1.1 verify queue", "label": "cell:active",
      "branch": "feat/v1-1", "branchExists": true, "blockerOnBranch": false,
      "pr": { "number": 301, "title": "[VERIFY]: V1.1", "state": "OPEN", "headSha": "$SHA_HEAD", "comments": [] } },
    { "number": 202, "title": "V1.2 verify reviewed", "label": "cell:active",
      "branch": "feat/v1-2", "branchExists": true, "blockerOnBranch": false,
      "pr": { "number": 302, "title": "[VERIFY]: V1.2", "state": "OPEN", "headSha": "$SHA_HEAD",
              "comments": ["VERIFIED: unit @ $SHA_HEAD\n\nnpm test\n40 passed"] } },
    { "number": 203, "title": "V1.3 verify stale", "label": "cell:active",
      "branch": "feat/v1-3", "branchExists": true, "blockerOnBranch": false,
      "pr": { "number": 303, "title": "[VERIFY]: V1.3", "state": "OPEN", "headSha": "$SHA_HEAD",
              "comments": ["VERIFIED: unit @ $SHA_OLD\n\nnpm test\n40 passed"] } },
    { "number": 204, "title": "V1.4 verify merged", "label": "cell:awaiting-lab",
      "branch": "feat/v1-4", "branchExists": true, "blockerOnBranch": false,
      "pr": { "number": 304, "title": "[VERIFY]: V1.4", "state": "MERGED", "headSha": "$SHA_HEAD", "comments": [] } },
    { "number": 205, "title": "V1.5 verify blocked", "label": "cell:active",
      "branch": "feat/v1-5", "branchExists": true, "blockerOnBranch": true,
      "pr": { "number": 305, "title": "[VERIFY]: V1.5", "state": "OPEN", "headSha": "$SHA_HEAD", "comments": [] } },
    { "number": 206, "title": "V1.6 ready, not verify", "label": "cell:active",
      "branch": "feat/v1-6", "branchExists": true, "blockerOnBranch": false,
      "pr": { "number": 306, "title": "[READY]: V1.6", "state": "OPEN", "headSha": "$SHA_HEAD", "comments": [] } }
  ]
}
JSON
OUT_V=$(bash "$SCRIPT" --state "$TMP/state-verify.json" 2>"$TMP/err-verify"); EXIT_V=$?
assert_eq 0 "$EXIT_V" "a [VERIFY] fixture run exits 0"
vrow() { printf '%s' "$OUT_V" | grep -E "^#$1 " || true; }
assert_contains "$(vrow 201)" "cell:awaiting-lab" "an open [VERIFY] PR with no stamp is awaiting-lab"
assert_contains "$(vrow 202)" "cell:awaiting-review" "an open [VERIFY] PR with a current stamp is awaiting-review"
assert_contains "$(vrow 203)" "cell:awaiting-lab" "an open [VERIFY] PR with a stale stamp is awaiting-lab"
assert_contains "$(vrow 204)" "cell:merged" "a merged [VERIFY] PR is cell:merged"
assert_contains "$(vrow 205)" "cell:awaiting-lab" "an open [VERIFY] PR without a stamp is awaiting-lab even with a blocker on its branch"
assert_contains "$(vrow 206)" "unchanged" "an open PR that is not [VERIFY] and has no stamp is left alone"
assert_not_contains "$(vrow 206)" "awaiting-lab" "only a [VERIFY] title earns awaiting-lab"

# The collector carries the PR title into the state, so the rule works on a
# live repo as well as on a fixture file.
cat > "$STUB/gh" <<'GH'
#!/usr/bin/env bash
case "$1 $2" in
  "issue list")
    cat <<'JSON'
[
  {"number": 91, "title": "W1.1 verify via collector", "state": "OPEN", "labels": [{"name": "cell:active"}]}
]
JSON
    ;;
  "pr list")
    cat <<'JSON'
[{"number": 92, "title": "[VERIFY]: W1.1", "body": "Closes #91", "state": "OPEN",
  "headRefName": "feat/w1-1", "headRefOid": "3333333333333333333333333333333333333333"}]
JSON
    ;;
  "api "*)
    case "$*" in
      *"/branches"*) printf '%s\n' development feat/w1-1 ;;
      *"BLOCKER.md"*) exit 1 ;;
      *) : ;;
    esac
    ;;
  *) exit 1 ;;
esac
GH
chmod +x "$STUB/gh"
OUT=$(GH_BIN="$STUB/gh" bash "$SCRIPT" --repo example/host 2>/dev/null)
assert_contains "$(printf '%s' "$OUT" | grep -E '^#91 ' || true)" "cell:awaiting-lab" "the collector derives awaiting-lab for an open [VERIFY] PR"

# --- a truncated collection must fail loudly, never derive from partial state
# Deriving labels from half a backlog is worse than not running: a package
# whose PR is beyond the cut looks branch-only and gets downgraded.
cat > "$STUB/gh" <<'GH'
#!/usr/bin/env bash
case "$1 $2" in
  "issue list")
    # Emit exactly as many issues as the requested --limit, which is what a
    # truncated page looks like from the outside.
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
  "pr list") echo '[]' ;;
  *) echo '[]' ;;
esac
GH
chmod +x "$STUB/gh"
OUT=$(GH_BIN="$STUB/gh" bash "$SCRIPT" --repo example/host 2>&1); EXIT=$?
assert_ne 0 "$EXIT" "a collection that fills the page limit fails rather than deriving from partial state"
assert_contains "$OUT" "truncat" "the truncation is named in the failure"

# --- several target repos in one run ----------------------------------------
# The model puts the issue graph in one host repo while PRs open against the
# target repo each package names. A program spanning fifteen sibling repos must
# not need fifteen runs, and must never report a confident partial for the
# repos it did not look at.
cat > "$STUB/gh" <<'GH'
#!/usr/bin/env bash
# Answers per --repo, so one stub serves a host and two target repos.
repo=""; prev=""
for a in "$@"; do [ "$prev" = "--repo" ] && repo="$a"; prev="$a"; done
case "$1 $2" in
  "issue list")
    cat <<'JSON'
[
  {"number": 21, "title": "A1.1 core change", "state": "CLOSED",
   "body": "**Part of** #1 · **Phase 1** · **Repo:** `example/code-a`",
   "labels": [{"name": "cell:queued"}]},
  {"number": 22, "title": "B1.1 client change", "state": "OPEN",
   "body": "**Part of** #1 · **Phase 1** · **Repo:** `example/code-b`",
   "labels": [{"name": "cell:queued"}]}
]
JSON
    ;;
  "pr list")
    case "$repo" in
      example/code-a) cat <<'JSON'
[{"number": 31, "title": "[READY]: A1.1", "body": "Closes #21", "state": "MERGED",
  "headRefName": "feat/a1-1", "headRefOid": "1111111111111111111111111111111111111111"}]
JSON
        ;;
      *) echo '[]' ;;
    esac
    ;;
  "api "*)
    case "$*" in
      *"code-a/branches"*) printf '%s\n' development feat/a1-1 ;;
      *"code-b/branches"*) printf '%s\n' development feat/b1-1-client ;;
      *"BLOCKER.md"*) exit 1 ;;
      *) echo '[]' ;;
    esac
    ;;
  *) exit 1 ;;
esac
GH
chmod +x "$STUB/gh"

OUT=$(GH_BIN="$STUB/gh" bash "$SCRIPT" --repo example/host         --target example/code-a --target example/code-b 2>"$TMP/err3")
EXIT=$?
assert_eq 0 "$EXIT" "two target repos are collected in one run"
r21=$(printf '%s' "$OUT" | grep -E '^#21 ' || true)
r22=$(printf '%s' "$OUT" | grep -E '^#22 ' || true)
assert_contains "$r21" "cell:merged" "a package in the first target repo derives from its own PR"
assert_contains "$r22" "cell:active" "a package in the second target repo derives from its own branch"

# --- a package whose repo was not covered must fail loudly ------------------
# The silent-partial failure this replaces: with only one target given, a
# package living in another repo matched no PR and no branch, and was reported
# as "unchanged" — indistinguishable from a package with genuinely nothing.
OUT2=$(GH_BIN="$STUB/gh" bash "$SCRIPT" --repo example/host --target example/code-a 2>&1)
EXIT2=$?
assert_ne 0 "$EXIT2" "a package whose target repo was not supplied fails the run"
assert_contains "$OUT2" "example/code-b" "the uncovered repo is named"
assert_contains "$OUT2" "B1.1" "the package that needs it is named"
assert_not_contains "$OUT2" "0 label(s) would change" "an uncovered repo never reports a clean result"

# --- --epic limits the run to one epic's packages ---------------------------
# Regression from a host repo with ~290 historical packages that made
# the per-package BLOCKER.md and PR-comment calls run past fleet's 10-minute
# limit, so a cycle for a six-package epic never derived anything. A package
# belongs to an epic by its header line: **Part of** #<epic>.

# Over a state file: the filter applies to the recorded partOf.
cat > "$TMP/state-epic.json" <<JSON
{
  "repo": "example/host",
  "targets": ["example/host"],
  "issues": [
    { "number": 61, "title": "L1.1 in the epic", "label": "cell:queued", "partOf": 60,
      "branch": "feat/l1-1", "branchExists": true, "blockerOnBranch": false, "pr": null },
    { "number": 71, "title": "T1.1 another epic", "label": "cell:queued", "partOf": 70,
      "branch": "feat/t1-1", "branchExists": true, "blockerOnBranch": false, "pr": null },
    { "number": 72, "title": "T1.2 no parent", "label": "cell:queued",
      "branch": "feat/t1-2", "branchExists": true, "blockerOnBranch": false, "pr": null }
  ]
}
JSON
OUT=$(bash "$SCRIPT" --state "$TMP/state-epic.json" --epic 60 --emit-state "$TMP/emitted-epic.json" 2>"$TMP/err-epic"); EXIT=$?
assert_eq 0 "$EXIT" "--epic over a state file exits 0"
assert_contains "$(printf '%s' "$OUT" | grep -E '^#61 ' || true)" "cell:active" "a package of the epic is derived"
assert_empty "$(printf '%s' "$OUT" | grep -E '^#71 ' || true)" "a package of another epic is not reported"
assert_empty "$(printf '%s' "$OUT" | grep -E '^#72 ' || true)" "a package with no Part of line is not reported"
emitted=$(node -e 'process.stdout.write(require(process.argv[1]).issues.map(i=>i.number).join(","))' "$TMP/emitted-epic.json")
assert_eq "61" "$emitted" "--emit-state under --epic holds only the epic's packages"

# Without --epic the same file still reports every package.
OUT=$(bash "$SCRIPT" --state "$TMP/state-epic.json" 2>/dev/null)
assert_contains "$(printf '%s' "$OUT" | grep -E '^#71 ' || true)" "cell:active" "without --epic every package is still derived"

# A non-numeric epic is a usage error, not an empty run.
OUT=$(bash "$SCRIPT" --state "$TMP/state-epic.json" --epic L 2>&1); EXIT=$?
assert_eq 64 "$EXIT" "a non-numeric --epic is a usage error"
assert_contains "$OUT" "--epic needs an issue number" "the usage error says what --epic takes"

# Through the collector: no per-package call is made for another epic's
# package, the epic is recorded, and an uncovered repo outside the epic does
# not fail the run.
cat > "$STUB/gh" <<'GH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_CALLS"
case "$1 $2" in
  "issue list")
    cat <<'JSON'
[
  {"number": 61, "title": "L1.1 in the epic", "state": "OPEN",
   "body": "**Part of** #60 · **Phase 1** · **Repo:** `example/host`",
   "labels": [{"name": "cell:queued"}]},
  {"number": 71, "title": "T1.1 another epic", "state": "CLOSED",
   "body": "**Part of** #70 · **Phase 1** · **Repo:** `example/host`",
   "labels": [{"name": "cell:active"}]},
  {"number": 73, "title": "U1.1 another epic, another repo", "state": "OPEN",
   "body": "**Part of** #70 · **Repo:** `example/elsewhere`",
   "labels": [{"name": "cell:queued"}]},
  {"number": 600, "title": "L1.10 epic number prefix", "state": "OPEN",
   "body": "**Part of** #600 · **Repo:** `example/host`",
   "labels": [{"name": "cell:queued"}]}
]
JSON
    ;;
  "pr list")
    cat <<'JSON'
[{"number": 81, "title": "[READY]: T1.1", "body": "Closes #71", "state": "MERGED",
  "headRefName": "feat/t1-1", "headRefOid": "1111111111111111111111111111111111111111"}]
JSON
    ;;
  "api "*)
    case "$*" in
      *"/branches"*) printf '%s\n' development feat/l1-1-x feat/t1-1 ;;
      *"BLOCKER.md"*) exit 1 ;;
      *) : ;;
    esac
    ;;
  *) exit 1 ;;
esac
GH
chmod +x "$STUB/gh"
: > "$STUB_CALLS"
OUT=$(GH_BIN="$STUB/gh" STUB_CALLS="$STUB_CALLS" bash "$SCRIPT" --repo example/host --epic 60 \
  --emit-state "$TMP/emitted-collector.json" 2>"$TMP/err-epic2"); EXIT=$?
assert_eq 0 "$EXIT" "--epic through the collector exits 0 despite an uncovered repo in another epic"
assert_contains "$(printf '%s' "$OUT" | grep -E '^#61 ' || true)" "cell:active" "the epic's package derives from its branch"
assert_empty "$(printf '%s' "$OUT" | grep -E '^#71 ' || true)" "another epic's merged package is not reported"
assert_empty "$(printf '%s' "$OUT" | grep -E '^#600 ' || true)" "Part of #600 does not match --epic 60"
calls=$(cat "$STUB_CALLS")
assert_not_contains "$calls" "ref=feat/t1-1" "no BLOCKER.md lookup is made for another epic's branch"
assert_not_contains "$calls" "issues/81/comments" "no PR comment fetch is made for another epic's PR"
assert_contains "$calls" "ref=feat/l1-1-x" "the epic's own branch is still checked for a blocker"
partof=$(node -e 'process.stdout.write(String(require(process.argv[1]).issues[0].partOf))' "$TMP/emitted-collector.json")
assert_eq "60" "$partof" "the collector records each package's epic as partOf"

finish
