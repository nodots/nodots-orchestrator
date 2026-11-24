# BLOCKER: X0.2 — `bash scripts/test.sh` cannot end `ALL PASS` in this worker environment

**Bucket:** on a missing capability
**Kind:** human-decision
**Reference:** nodots/nodots-orchestrator#244; `scripts/tests/gate-h-hardening.test.sh`, `scripts/tests/check-secrets.test.sh`, `scripts/tests/v0-gate.test.sh`
**Owner:** coordinator
**Un-blocks when:** `bash scripts/test.sh` ends `ALL PASS` on a host that can run the gitleaks binary and finishes in under ten minutes, or the coordinator accepts the per-test evidence below as the VERIFIED stamp

## What was needed, and why

The package is implemented and committed. The only `standards.json` check is `bash scripts/test.sh`, and the contract requires its summary in the VERIFIED stamp. It cannot be produced here. Both failures are in `scripts/**`, which this lane forbids, and neither touches a file this package changed.

- `bash scripts/test.sh` ran twice and was killed both times at the ten-minute background limit with no output. Run one at a time, `scripts/tests/v0-gate.test.sh` alone exceeded 500s; this is what stalls the full run.
- `scripts/tests/gate-h-hardening.test.sh` (3 failed of 27) and `scripts/tests/check-secrets.test.sh` (4 failed of 20) fail deterministically: `scripts/check-secrets.sh:93 ... gitleaks: cannot execute binary file: Exec format error`. The fixture runs a gitleaks binary built for another OS or architecture on this darwin host (exit 126).

Every other fixture test passes run alone: all 15 under `assets/tests/` that I ran, including `require-coordinator.test.sh` (94 checks, 0 failed); all of `plugins/fleet/tests/`; and the rest of `scripts/tests/` apart from the three above. `scripts/check-syntax.sh` passes. I did not run `check-credentials.sh` or the `evals/` node tests on their own.

## Alternatives searched
- Re-run the full suite — the second run was killed at the same limit; the gitleaks failure is deterministic, so no further re-run.
- Edit `scripts/**` or the fixtures to skip gitleaks or the slow gate — forbidden by SCOPE.json, and relaxing a test to get green is what the contract rules out.
- Stamp the per-test results as `ALL PASS` — not what was run.

## The ask
X0.2-1: Should the coordinator run `bash scripts/test.sh` on a host with a working gitleaks and stamp the PR, or accept the per-test results above in its place? : run it on a capable host : decide-by the next fleet cycle : cost-of-waiting #244 stays out of review.
