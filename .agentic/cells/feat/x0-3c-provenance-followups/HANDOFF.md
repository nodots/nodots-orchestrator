# HANDOFF: X0.3c provenance follow-ups

## Done (uncommitted at time of writing, attempt 2)
- `plugins/fleet/src/cycle.js` (held in-flight verify loop, ~L218-223): when the
  GET `/runs/<id>` fails, raises `verify-unreachable` with the detail shape of
  `plugins/fleet/src/verify.js:168` (`...; run <id> for PR #<pr> is kept`), on
  the package issue, and keeps/sets aside the record as before.
- `plugins/fleet/tests/provenance.test.sh`:
  - section G': coordinator labeled agent-ready, jack unlabeled it, coordinator
    labeled worker:a; #11 stays trusted and promoted. A mutant copy of fleet
    (tracker.js treats `unlabeled` as `labeled`) flags #11 on the same fixture,
    asserted in-test.
  - section H'''': held #13's run with verifier killed -> verify-unreachable on
    #13, in-flight record for PR #200 kept, report action `held`.

## State (end of attempt 2)
- Committed on the branch. `bash scripts/test.sh` ran (takes >10 min): the
  package's suite `provenance.test.sh` is 102/0. The overall result is `FAILED`
  because of four suites outside the lane. See `BLOCKER.md` next to this file.
- Not done: proving H'''' fails against the pre-change `cycle.js`. Running
  `provenance.test.sh` alone needed approval, and the session had no approval
  surface.

## Next (once BLOCKER.md is decided)
1. `bash scripts/test.sh` must end `ALL PASS`.
2. Prove H'''' fails against `git show 5d4a03b:plugins/fleet/src/cycle.js`.
3. Commit, push, open `[READY]: X0.3c` PR (body `Closes #264`), quote the
   mutant run, post VERIFIED stamp at head sha.

Note: root `HANDOFF.md` is from G2.4, not this package.

## Plan check

Package issue still matches: yes
