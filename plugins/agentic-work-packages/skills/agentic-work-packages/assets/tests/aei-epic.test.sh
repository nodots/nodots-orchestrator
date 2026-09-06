#!/usr/bin/env bash
# Fixture test for aei-epic.js (N-14).
#
# Three fixture epics: one with an open unblocked package (must enumerate as
# actionable), one where every open package carries a kind and a reference
# (must enumerate as excused), and one with a malformed line (must fail closed).
set -uo pipefail
cd "$(dirname "$0")"
. ./lib.sh

SCRIPT="$(cd ../scripts && pwd -P)/aei-epic.js"
assert_file "$SCRIPT" "aei-epic.js exists"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# jget <json-file> <node expression over `d`>
jget() { node -e '
  const d = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
  const v = eval(process.argv[2]);
  process.stdout.write(v === undefined ? "" : String(v));
' "$1" "$2"; }

# --- fixture 1: one open unblocked package -----------------------------------
cat > "$TMP/actionable.md" <<'MD'
# Epic: multiplayer

## Definition of done (every package)
- [ ] Acceptance criteria met
- [ ] Tests pass

## Workstreams & packages

**Phase 0 · Contract**
- [x] #101 · M0.1 Freeze the move-protocol package
- [x] #102 · **V0 gate** — protocol round-trips

**Phase 1 · Server**
- [ ] #105 · M1.3 Server-side move validation
- [ ] #110 · M1.1k Session expiry sweep :: blocker:human-decision=product-owner
- [ ] M2.4 Spectator mode

## References
- nothing here is a package
MD
node "$SCRIPT" --epic-file "$TMP/actionable.md" > "$TMP/out1.json" 2>"$TMP/err1"
assert_eq 0 "$?" "an epic with one open unblocked package enumerates"
assert_empty "$(cat "$TMP/err1")" "a clean enumeration writes nothing to stderr"
assert_eq 1 "$(jget "$TMP/out1.json" 'd.version')" "protocol version 1"
assert_eq 5 "$(jget "$TMP/out1.json" 'd.items.length')" "only the workstreams checkboxes are items"
assert_eq "" "$(jget "$TMP/out1.json" 'd.items.find(i => i.title.includes("Acceptance criteria")) || ""')" \
  "the definition-of-done checkboxes are not enumerated"
assert_eq "closed" "$(jget "$TMP/out1.json" 'd.items.find(i => i.id === "M0.1").state')" "a ticked box is closed"
assert_eq "V0" "$(jget "$TMP/out1.json" 'd.items[1].id')" "a gate line yields the gate id"
assert_eq "open" "$(jget "$TMP/out1.json" 'd.items.find(i => i.id === "M1.3").state')" "an unticked box with an issue is open"
assert_eq "true" "$(jget "$TMP/out1.json" 'd.items.find(i => i.id === "M1.3").granted')" "a filed package is granted"
assert_eq "" "$(jget "$TMP/out1.json" 'd.items.find(i => i.id === "M1.3").blocker || ""')" \
  "an open package with no blocker suffix carries no blocker — it is actionable"
assert_eq "human-decision" "$(jget "$TMP/out1.json" 'd.items.find(i => i.id === "M1.1k").blocker.kind')" "the blocker kind is carried"
assert_eq "product-owner" "$(jget "$TMP/out1.json" 'd.items.find(i => i.id === "M1.1k").blocker.ref')" "the blocker reference is carried"
assert_eq "proposed" "$(jget "$TMP/out1.json" 'd.items.find(i => i.id === "M2.4").state')" "a checkbox with no issue is proposed"
assert_eq "false" "$(jget "$TMP/out1.json" 'd.items.find(i => i.id === "M2.4").granted')" "a proposed entry is not granted"

# The guard's question: is any granted, open item free of a terminal blocker?
assert_eq 1 "$(jget "$TMP/out1.json" 'd.items.filter(i => i.state === "open" && i.granted && !i.blocker).length')" \
  "exactly one item is actionable, so a stop over this epic must be denied"

# --- fixture 2: every open package blocked, with kind and reference ----------
cat > "$TMP/blocked.md" <<'MD'
# Epic: multiplayer

## Workstreams & packages

- [x] #101 · M0.1 Freeze the move-protocol package
- [ ] #105 · M1.3 Server-side move validation :: blocker:tracked-task=#210
- [ ] #110 · M1.1k Session expiry sweep :: blocker:human-decision=product-owner :: observed=2026-09-06T10:00:00Z :: evidence=asked on the epic thread
- [ ] #111 · M1.5 Rate limiting :: blocker:not-before=2026-09-20T00:00:00Z
MD
node "$SCRIPT" --epic-file "$TMP/blocked.md" > "$TMP/out2.json" 2>"$TMP/err2"
assert_eq 0 "$?" "a fully blocked epic enumerates"
assert_eq 0 "$(jget "$TMP/out2.json" 'd.items.filter(i => i.state === "open" && i.granted && !i.blocker).length')" \
  "no item is actionable, so a stop over this epic may be allowed"
assert_eq "asked on the epic thread" "$(jget "$TMP/out2.json" 'd.items.find(i => i.id === "M1.1k").blocker.evidence')" \
  "evidence is carried when present"
assert_eq "2026-09-06T10:00:00Z" "$(jget "$TMP/out2.json" 'd.items.find(i => i.id === "M1.1k").blocker.observed_at_utc')" \
  "the observation time is carried when present"

# --- fixture 3: fails closed -------------------------------------------------
fails_closed() { # <file> <label> <expected stderr fragment>
  local out err code
  out=$(node "$SCRIPT" --epic-file "$1" 2>"$TMP/e"); code=$?
  err=$(cat "$TMP/e")
  assert_ne 0 "$code" "$2: non-zero exit"
  assert_empty "$out" "$2: nothing on stdout"
  assert_contains "$err" "$3" "$2: the reason is stated"
}

printf '# Epic\n\n## Workstreams & packages\n\n- [ ] #105 · M1.3 fine\n- [~] #106 broken marker\n' > "$TMP/bad1.md"
fails_closed "$TMP/bad1.md" "a malformed checklist line" "malformed checklist line"

printf '# Epic\n\n## Workstreams & packages\n\n- [ ] #105 · M1.3 a\n- [ ] #106 · M1.3 duplicate\n' > "$TMP/bad2.md"
fails_closed "$TMP/bad2.md" "a duplicate package id" "duplicate package id"

printf '# Epic\n\n## Workstreams & packages\n\n- [ ] #105 · M1.3 a :: blocker:because-hard=reasons\n' > "$TMP/bad3.md"
fails_closed "$TMP/bad3.md" "a blocker kind outside the vocabulary" "unknown blocker kind"

printf '# Epic\n\n## Workstreams & packages\n\n- [ ] #105 · M1.3 a :: blocker:tracked-task\n' > "$TMP/bad4.md"
fails_closed "$TMP/bad4.md" "a blocker suffix with no reference" "malformed blocker suffix"

printf '# Epic\n\n## Context\n\nno workstreams here\n' > "$TMP/bad5.md"
fails_closed "$TMP/bad5.md" "an epic with no workstreams section" "nothing to enumerate"

fails_closed "$TMP/does-not-exist.md" "an unreadable source" "could not read"

# --- an empty backlog is a valid enumeration, never an error -----------------
printf '# Epic\n\n## Workstreams & packages\n\n_(none yet)_\n\n## References\n' > "$TMP/empty.md"
node "$SCRIPT" --epic-file "$TMP/empty.md" > "$TMP/out3.json" 2>/dev/null
assert_eq 0 "$?" "an empty workstreams section is a valid enumeration"
assert_eq 0 "$(jget "$TMP/out3.json" 'd.items.length')" "an empty enumeration has no items"

# --- the provider accepts no item list from its caller -----------------------
out=$(node "$SCRIPT" --epic-file "$TMP/empty.md" --items '[{"id":"X","state":"closed"}]' 2>&1); code=$?
assert_ne 0 "$code" "there is no flag for supplying items"
assert_contains "$out" "unknown argument" "an items flag is rejected as unknown"
assert_not_contains "$(grep -c -- '--items' "$SCRIPT" || true)" "1" "the source has no --items option"

finish
