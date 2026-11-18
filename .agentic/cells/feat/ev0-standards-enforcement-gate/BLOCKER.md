# BLOCKER: EV0 — `bash scripts/test.sh` cannot reach ALL PASS in this environment

**Bucket:** on a missing capability
**Kind:** human-decision
**Reference:** nodots/nodots-orchestrator#224; scripts/check-secrets.sh:93
**Owner:** coordinator
**Un-blocks when:** `bash scripts/test.sh` ends `ALL PASS` on a machine with a runnable gitleaks, or CI's `standards` job passes on this branch's PR

## What was needed, and why
The one `checks[]` entry is `test: bash scripts/test.sh`, and the VERIFIED stamp needs it to end `ALL PASS`. Here it did not:
- The new gate `ev0-standards-enforcement-gate.test.sh` passes: `--- 14 checks, 0 failed`. Standalone, and inside test.sh.
- `scripts/tests/check-secrets.test.sh` (4 of 20 failed) and `scripts/tests/gate-h-hardening.test.sh` (3 of 27 failed) fail with `gitleaks exited 126 ... cannot execute binary file: Exec format error` from scripts/check-secrets.sh:93. The gitleaks binary the tests fetch has the wrong architecture for this Darwin host. Deterministic, so not re-run.
- The run then stopped making progress, was killed at the 10 minute background limit, and never printed `ALL PASS` or `FAILED`. Which test hung is undiagnosed: `ps` was denied. It was not re-run, because the red was not infrastructure-classified.
Both causes sit under `scripts/**`, which is forbidden for this lane.

Also not shown: the acceptance item "each case fails against the tree before its package". It needs a worktree at `f694bad^` / `adaef0b^` outside this worktree; both attempts were denied.

## Alternatives searched
- Re-run test.sh — a deterministic red gets zero re-runs, and the hang is not a known transient.
- Fix or skip the gitleaks tests — `scripts/**` is forbidden and relaxing them is not allowed.
- Stamp VERIFIED anyway — it would assert a green that was not observed.

## The ask
EV0-1: run test.sh where gitleaks executes, or accept CI's `standards` job as the stamp source? : run it on the CI runner and stamp from that : decide-by the PR's CI run : cost-of-waiting E0.4 stays blocked
