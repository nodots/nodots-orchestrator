# BLOCKER: E0.2 — the macOS run has a third red file that decision E0.2-B1 does not except

**Bucket:** blocked on a decision
**Kind:** human-decision
**Reference:** decision E0.2-B1 (#219); PR #227; `scripts/tests/v0-gate.test.sh:59-62`
**Owner:** the coordinator
**Un-blocks when:** the coordinator records whether the `v0-gate.test.sh` red is excepted under E0.2-B1

## What was needed, and why

Decision E0.2-B1 (recorded in this cell's `HANDOFF.md`) lets the CI run stand in
for the macOS run. It allows `check-secrets.test.sh` and `gate-h-hardening.test.sh`
to be red in the local run, and says any other local red still blocks.

Status at head `260ee10ff5a4eda396b0c9cb5c5b1c3044b3bab2`:

- CI `Fixture tests` passed: run 44179885654,
  https://github.com/nodots/nodots-orchestrator/actions/runs/44179885654/job/134381054901
  (started 21:26:48Z, finished 21:55:05Z).
- The local `bash scripts/test.sh` on Darwin arm64 finished with `FAILED`, exit 1,
  after about 30 minutes. Three files were red:

```
FAIL  scripts/tests/check-secrets.test.sh  --- 20 checks, 4 failed
FAIL  scripts/tests/gate-h-hardening.test.sh  --- 27 checks, 3 failed
FAIL  scripts/tests/v0-gate.test.sh  --- 11 checks, 2 failed
```

The third file is the run that stalled last attempt. It did not hang; it was
slow. `v0-gate.test.sh` runs the whole suite four times on copies of the repo
(`:59-78`). Its two failures are `clean copy: test.sh exits 0` and
`clean copy: test.sh prints ALL PASS`. In the nested output, the copy's only red
files are `check-secrets.test.sh` and `gate-h-hardening.test.sh`, both with
`gitleaks exited 126 ... Exec format error`. Every other file in the copy prints
`PASS`. So it has the same cause as the two excepted files, the Linux gitleaks pin
at `scripts/check-secrets.sh:31`. But the decision's text does not except it, and
the previous attempt could not have seen it.

The `[READY]:` PR #227 is open. No VERIFIED stamp has been posted, so its
`Stamp check` job is red, which is accurate.

## Alternatives searched

- Stamp anyway, because the red has the same cause. This fails because E0.2-B1
  says "Any other local red still blocks". Reading that rule loosely is the
  coordinator's call, not mine.
- Re-run the local suite. This fails because the red is deterministic (contract
  §5: zero re-runs) and would only repeat.
- Make `check-secrets.sh` platform-aware so all three go green. This fails
  because `scripts/**` is forbidden for this lane. It is option (b) of E0.2-B1.

## The ask

E0.2-B2: Does E0.2-B1's exception cover `scripts/tests/v0-gate.test.sh` when its
only failures come from the nested run's two excepted gitleaks files?
Options: (a) yes, extend the exception to `v0-gate.test.sh` for this cause; the
next worker stamps `VERIFIED: ci-<run id> @ <head sha>` from the green CI run
for the then-current head. This commit moves the head past `260ee10`, so run
44179885654 no longer covers it;
(b) no, and E0.2 waits for the platform-aware `check-secrets.sh` package.
Recommendation: (a). The nested output shows no cause besides the excepted one.
Decide-by: before E0.3 or the workflow package depends on E0.2.
Cost-of-waiting: E0.2 stays unmerged, and so does every package that calls `run-checks.js`.
