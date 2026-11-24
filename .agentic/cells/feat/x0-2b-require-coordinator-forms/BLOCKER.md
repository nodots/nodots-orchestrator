# BLOCKER: X0.2b — `bash scripts/test.sh` cannot pass on this worker's host (darwin)

**Bucket:** blocked on a missing capability
**Kind:** human-decision
**Reference:** `scripts/check-secrets.sh:31,67` (gitleaks pin `gitleaks_8.30.1_linux_x64.tar.gz`); head `1c511e74db4da2912fa13e477cea10719647312a`
**Owner:** coordinator
**Un-blocks when:** `bash scripts/test.sh` ends `ALL PASS` on head `1c511e7` (or its successor) on a Linux-x86_64 host, or with `GITLEAKS_ARCHIVE` set to a darwin archive, and the result is stamped on the PR

## What was needed, and why
The contract (§6.2) and the acceptance criteria require every `checks[]` command to pass before `[READY]`. The package work is done and pushed (see HANDOFF.md; `require-coordinator.test.sh` 275 checks, 0 failed). On this host (Darwin arm64), `bash scripts/test.sh` gave:

- `FAIL  scripts/tests/check-secrets.test.sh  --- 20 checks, 4 failed` and
  `FAIL  scripts/tests/gate-h-hardening.test.sh  --- 27 checks, 3 failed`, both
  `gitleaks exited 126: .../gitleaks: cannot execute binary file: Exec format error`.
  The pinned gitleaks archive is a Linux x64 binary. This red is deterministic, and its cause is in `scripts/**`, a forbidden path.
- After `PASS  scripts/tests/test-sh.test.sh  --- 66 checks, 0 failed` the run printed nothing more, and the tool runner killed it at its 30-minute background limit, before `=== eval tests ===`. An earlier run on this branch also passed 10 minutes without finishing. I did not find the cause.

None of the failing tests touch the files this package changes. Every other test file reported PASS, including `require-coordinator.test.sh` (275 checks, 0 failed) and the hook byte-identity check.

## Alternatives searched
- Re-run on this host: the red is deterministic (the same Exec format error every time, and it maps to `check-secrets.sh:31`). The contract allows zero re-runs.
- Set `GITLEAKS_ARCHIVE` to a darwin archive: the script checks the archive against the pinned linux SHA-256 (`check-secrets.sh` checksum test), so a darwin archive fails the checksum. Changing the pin is under `scripts/**`, which is forbidden.
- Skip the check-secrets tests: that relaxes a check until it holds, which the contract forbids.

## The ask
X0.2b-1: Where should the stamp for X0.2b come from? (a) The coordinator or CI runs `bash scripts/test.sh` on Linux at head `1c511e7` and stamps it. (b) A package that makes `check-secrets.sh` portable to darwin, after which this worker re-runs. : recommend (a); the change is confined to one hook and its test, and those pass. : decide-by the next coordinator cycle : cost-of-waiting: X0.2b is not merged, so the function, find -exec, parallel and here-string forms still get past the hook.
