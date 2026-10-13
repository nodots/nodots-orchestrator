# BLOCKER: G1.1 - bash scripts/test.sh is red in plugins/fleet, outside this lane

**Bucket:** on a decision
**Kind:** human-decision
**Reference:** nodots/nodots-orchestrator issue #29; failing files plugins/fleet/tests/ci-preconditions.test.sh and plugins/fleet/tests/cycle.test.sh
**Owner:** coordinator
**Un-blocks when:** `bash scripts/test.sh` exits 0 on this branch, or the coordinator records that these two failures are known on `development` and may be ignored for this PR

## What was needed, and why

The completion protocol requires tests to pass before a `[READY]:` PR. REVIEW.md and
`scripts/tests/review-md.test.sh` are written. The new test failed before REVIEW.md
existed (1 check, 1 failed: no such file) and passes after (20 checks, 0 failed).

The full run, `bash scripts/test.sh`, ends `FAILED` for two files this package does not touch:

- `plugins/fleet/tests/ci-preconditions.test.sh` - 25 checks, 14 failed. Launch and
  alarm assertions for the G4.1 CI preconditions get empty results (for example
  `expected [10 12], got []`).
- `plugins/fleet/tests/cycle.test.sh` - 122 checks, 2 failed, one of them
  "an untrusted workspace is refused at launch with a trust alarm" (the cycle
  reported movement and no alarm). The second failure was in truncated output.

My diff against `origin/development` is `.agentic/cells/.../SCOPE.json` plus the
two files in `allowedPaths`. `plugins/fleet/**` is outside `allowedPaths`. I did not
re-run the suite: the failure shapes are deterministic and map to fleet code paths.
I have not established whether `development` is red the same way; the shell
allowed only this worktree and I did not check out a second tree.

## Alternatives searched

- Fix the fleet tests or fleet code - outside `allowedPaths`; widening the lane is a coordinator decision.
- Open the PR with a note that the red is unrelated - the contract requires a green suite for `[READY]`, and a stamp over a red run would be false.
- Re-run until green - forbidden for a deterministic red.
- Skip or relax the failing assertions - forbidden.

## The ask

G1.1-a: The fleet tests fail on this branch for reasons outside the package. Options: (1) confirm they are red on `development` and open the PR with that stated; (2) fix them in a separate package first, then rebase this branch. : recommendation: check `development` first, then pick (1) or (2) : decide-by the next coordinator cycle : cost-of-waiting G1.1 stays unmerged; the work itself is complete and waiting on a green suite.
