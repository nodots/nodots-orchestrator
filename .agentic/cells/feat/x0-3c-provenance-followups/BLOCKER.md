# BLOCKER: X0.3c — `bash scripts/test.sh` is red in four suites outside this lane

**Bucket:** on a decision
**Kind:** human-decision
**Reference:** #264, #242 (X-B1); merges #230 (H0.8 fleet install) and #263 (X0.4 doctor provenance) into `development`
**Owner:** coordinator
**Un-blocks when:** `bash scripts/test.sh` ends `ALL PASS` on `development` merged into this branch, or the coordinator records that X-B1 is waived for these named reds

## What was needed, and why
Contract §6.2 and acceptance criterion "Every check in `.claude/standards.json`
passes" need `bash scripts/test.sh` to end `ALL PASS`. On this branch it ends
`FAILED`. The package's own suite is green:
`PASS plugins/fleet/tests/provenance.test.sh --- 102 checks, 0 failed`, and so
are `cycle.test.sh` (126/0) and `verify-stage.test.sh` (90/0).

The reds, each deterministic (§5: zero re-runs):

1. `plugins/fleet/tests/doctor-provenance.test.sh` (5 failed) and
   `plugins/fleet/tests/install.test.sh` (1 failed, "E: five files and three
   registrations are ok — expected [8], got [9]"). Doctor reports
   `hook registration PreToolUse in acme/api: .claude/settings.json on origin/main does not register node "$CLAUDE_PROJECT_DIR/.claude/hooks/require-coordinator.js"`.
   The doctor's expected set now has a fourth registration (require-coordinator)
   that install's fixtures/target do not carry. No file under
   `plugins/fleet/src`, `bin` or `tests` names `require-coordinator` (grep), so
   the expectation comes from the agentic-work-packages plugin's hook
   registrations. This is an interaction between #230 and #263 on
   `development`. This branch changes only `cycle.js` and
   `provenance.test.sh`, and nothing in doctor/install requires `cycle.js`.
2. `scripts/tests/check-secrets.test.sh` (4 failed) and
   `scripts/tests/gate-h-hardening.test.sh` (3 failed): `gitleaks exited 126:
   ... gitleaks: cannot execute binary file: Exec format error`. The pinned
   gitleaks archive is for a different platform than this darwin host. That's an
   environment fault, not code.
3. `scripts/tests/v0-gate.test.sh` (2 failed) reruns `test.sh` on a clean
   copy, so it fails because of 1 and 2.

## Alternatives searched
- Fix doctor/install expectations: `plugins/fleet/src/install.js`, `bin/**`,
  `plugins/agentic-work-packages/**` and `tests/stubs/**` are outside
  `allowedPaths` or in `forbiddenPaths`.
- Fix gitleaks platform: `scripts/**` is forbidden, and it's a host matter.
- Re-run until green: forbidden by §5 for deterministic reds.
- Open `[READY]` anyway: a stamp would quote a red check, which contradicts X-B1.

## The ask
X0.3c-B1: (a) land a fix for the doctor/install `require-coordinator`
registration mismatch on `development` and run checks on a host where gitleaks
executes, then re-dispatch to stamp; or (b) waive X-B1 for exactly these four
suites and let this branch go `[READY]` with them quoted : recommend (a) :
decide-by next coordinator cycle : cost-of-waiting X0.3c (already implemented,
committed on this branch) cannot be stamped or merged.
