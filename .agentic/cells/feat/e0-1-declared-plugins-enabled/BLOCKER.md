# BLOCKER: E0.1 — `bash scripts/test.sh` cannot pass on this host (gitleaks binary is Linux-only)

**Bucket:** blocked on a decision
**Kind:** human-decision
**Reference:** `scripts/check-secrets.sh:31,67` (pins `gitleaks_8.30.1_linux_x64.tar.gz`); issue #220
**Owner:** the coordinator
**Un-blocks when:** the coordinator records which host's `bash scripts/test.sh` run counts as the stamp for E0.1, or a Linux run of it on the head sha is available

## What was needed, and why

The worker contract §6.2 requires every `checks[]` command to pass, run in the
worktree, before `[READY]`. The one check is `test: bash scripts/test.sh`.

On head `c6d5973726640bd9d437589206f6837e6475dd2f`, on this host (Darwin arm64),
it ends `FAILED`. Every failure is gitleaks not executing:

```
FAIL  scripts/tests/check-secrets.test.sh  --- 20 checks, 4 failed
      FAIL  gitleaks exited 126:   (… gitleaks: cannot execute binary file: Exec format error)
FAIL  scripts/tests/gate-h-hardening.test.sh  --- 27 checks, 3 failed
      FAIL  gitleaks exited 126:
FAIL  scripts/tests/v0-gate.test.sh  --- 11 checks, 2 failed
      (its clean-copy run of test.sh fails on the same two suites)
FAILED
```

Deterministic: identical in two full runs. Not caused by this package: the
diff against `development` touches nothing under `scripts/`, so `development`
fails the same way on this host. `scripts/**` is in `forbiddenPaths`.

Everything this package governs passes in that same run:

```
PASS  …/assets/tests/check-standards.test.sh  --- 119 checks, 0 failed
PASS  …/assets/tests/sv0-standards-gate.test.sh  --- 86 checks, 0 failed
PASS  plugins/fleet/tests/standards-launch.test.sh  --- 73 checks, 0 failed
PASS  plugins/fleet/tests/sv1-standards-gate.test.sh  --- 46 checks, 0 failed
PASS  evals/gates/sv1-standards.test.js  --- 17 checks, 0 failed
```

The work is done and pushed on `feat/e0-1-declared-plugins-enabled` at
`c6d5973`; see `HANDOFF.md` here. No PR is open, because `[READY]` requires a
passing stamp for the head sha.

## Alternatives searched

- `GITLEAKS_ARCHIVE` pointing at a darwin_arm64 archive — `check-secrets.sh`
  applies the pinned SHA-256 to any archive (`:25`, `:79-80`), so it refuses.
- Editing `scripts/check-secrets.sh` or its tests to add a darwin archive —
  `scripts/**` is forbidden to this lane, and it is a separate change.
- Stamping with the three suites marked as excused — a stamp of a red run is not
  a passing check; the contract forbids relaxing it.
- Running the suite on a Linux host — none is available to this worker.

## The ask

E0.1-host: which run clears `[READY]` for E0.1? Options: (a) run
`bash scripts/test.sh` on Linux (CI, `ci.yml` pins Node 20 on ubuntu) at
`c6d5973` and stamp from it; (b) accept this host's run with the three gitleaks
suites excused as host-bound; (c) a separate package adds a darwin_arm64 pin to
`check-secrets.sh`, then re-run here. : recommend (a), with (c) filed so local
macOS workers can stamp : decide-by the next coordinator cycle : cost-of-waiting
E0.1 stays unmerged, and E0.3 (CI running the validator) waits on it.
