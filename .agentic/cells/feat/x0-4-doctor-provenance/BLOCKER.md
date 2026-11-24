# BLOCKER: X0.4 — `bash scripts/test.sh` fails on the gitleaks tests on this host, so [READY] cannot be stamped

**Bucket:** blocked on a merge
**Kind:** tracked-task
**Reference:** X-B1 (named by the coordinator in X0.4-D1 on #246: "X-B1 covers the gitleaks failures")
**Owner:** the coordinator
**Un-blocks when:** X-B1 merges to `development` (or the coordinator records that X0.4 may be stamped on a CI run instead of a local one)

## What was needed, and why

The package's code and tests are done (see HANDOFF.md). The X0.4 tests pass:
`plugins/fleet/tests/doctor-provenance.test.sh --- 27 checks, 0 failed`,
`plugins/fleet/tests/doctor-allow-rules.test.sh --- 26 checks, 0 failed`.

`bash scripts/test.sh` at d4afc66 ends `FAILED` (exit 1). Every failing check is gitleaks failing to run:

```
FAIL  scripts/tests/check-secrets.test.sh  --- 20 checks, 4 failed
      FAIL  gitleaks exited 126:
            scripts/check-secrets.sh: line 93: .../gitleaks: cannot execute binary file: Exec format error
FAIL  scripts/tests/gate-h-hardening.test.sh  --- 27 checks, 3 failed   (same error)
FAIL  scripts/tests/v0-gate.test.sh  --- 11 checks, 2 failed   (clean copy runs test.sh, which hits the two above)
```

Cause: `scripts/check-secrets.sh:31` pins `gitleaks_8.30.1_linux_x64.tar.gz`. This host is
Darwin arm64 (`uname -m` → `arm64`), so the extracted binary cannot execute. The red is
deterministic and independent of this package's diff. The fix lives under `scripts/**`,
which this lane forbids.

## Alternatives searched
- Fix `scripts/check-secrets.sh` or its tests here. They are in `forbiddenPaths`, and X-B1 owns that work.
- Stamp anyway, quoting the failure. The contract says `[READY]` means every check passes; a stamp with a red check is a false READY.
- Re-run. This is a deterministic red (exec format error), so it gets zero re-runs under §5.

## The ask
X0.4-B1: How should X0.4 reach `[READY]` while the gitleaks tests fail on darwin? (a) wait for X-B1 to merge, rebase, re-run, and stamp; (b) accept a stamp from a Linux x86_64 run (CI); (c) accept a local stamp that lists the three gitleaks failures as X-B1's. : (a), or (b) if X-B1 is far off : decide-by X-B1's next status change : cost-of-waiting X0.4's merge, and anything in #242 that depends on it.
