# BLOCKER: X0.1 — `bash scripts/test.sh` cannot end ALL PASS on this host (gitleaks is linux_x64 only)

**Bucket:** on a missing capability
**Kind:** human-decision
**Reference:** nodots/nodots-orchestrator#243; scripts/check-secrets.sh:93; scripts/tests/{check-secrets,gate-h-hardening,v0-gate}.test.sh
**Owner:** coordinator
**Un-blocks when:** `bash scripts/test.sh` ends `ALL PASS` at this branch head, run on a linux x64 host (CI) or with a darwin-arm64 gitleaks 8.30.1 archive the script accepts

## What was needed, and why
The completion protocol needs `test: bash scripts/test.sh` to end `ALL PASS` before `[READY]: X0.1` and the VERIFIED stamp. On this host (Darwin arm64) it ends `FAILED`: 3 test files fail (`check-secrets.test.sh` 4 checks, `gate-h-hardening.test.sh` 3 checks, `v0-gate.test.sh` 2 checks). Every failing check is a real gitleaks scan; `scripts/check-secrets.sh` pins the `linux_x64` 8.30.1 archive and the binary dies with `gitleaks exited 126 ... cannot execute binary file: Exec format error`. All other tests pass, including the new `plugins/fleet/tests/review-verdict.test.sh` (17 checks) and `review-stage`/`gate-r-review`, unchanged. Same deterministic failure shape, so no re-run (the first full run was only a 10-minute timeout, re-run once, per §5). The fix lives in `scripts/**`, which is forbidden to this lane.

## Alternatives searched
- Re-run the suite — deterministic exec-format error, zero re-runs allowed.
- Edit scripts/check-secrets.sh or the tests for arm64 — outside allowedPaths (`scripts/**` forbidden).
- Open `[READY]` with the failures noted — a stamp would assert a green that did not happen.

## The ask
X0.1-A: Accept CI (linux x64) as the authority for the `test` check and let a worker stamp from it, or supply a darwin-arm64 gitleaks archive? : accept CI result, then open `[READY]` from the pushed head : decide-by next coordinator cycle : cost-of-waiting #243 stays unmerged; the code change is complete and pushed.
