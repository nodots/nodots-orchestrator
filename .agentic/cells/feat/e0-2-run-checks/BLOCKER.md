# BLOCKER: E0.2 — `bash scripts/test.sh` is red on this host for a cause outside the lane

**Bucket:** blocked on a decision
**Kind:** human-decision
**Reference:** `scripts/check-secrets.sh:31`, `:67-68`; `scripts/tests/check-secrets.test.sh:71-72`; `scripts/tests/gate-h-hardening.test.sh`
**Owner:** the coordinator
**Un-blocks when:** `bash scripts/test.sh` ends `ALL PASS` on a host where the pinned gitleaks binary runs (Linux x86_64 or CI), or the coordinator records that a Linux CI run stands in for the local run

## What was needed, and why

Contract §6.2 requires every `checks[]` command to pass before `[READY]`. The
one check, `bash scripts/test.sh`, ran on the head `adaef0bd30b7f56981915af7422d502704c29b1c`
and printed `FAIL` for two files:

```
FAIL  scripts/tests/check-secrets.test.sh  --- 20 checks, 4 failed
FAIL  scripts/tests/gate-h-hardening.test.sh  --- 27 checks, 3 failed
```

Every failing assertion has the same cause:

```
FAIL  gitleaks exited 126:
  scripts/check-secrets.sh: line 93: .../gitleaks: cannot execute binary file: Exec format error
```

`scripts/check-secrets.sh:31` pins `gitleaks_8.30.1_linux_x64.tar.gz`. This host
is `Darwin arm64` (`uname -sm`), so the Linux binary cannot run. The red is
deterministic and platform-bound, so under contract §5 it gets no re-run. Its
cause is under `scripts/**`, which is in this lane's `forbiddenPaths`. This
package's diff adds only `run-checks.js`, `run-checks.test.sh` and the cell
files, and none of them is on that code path.

Everything else is green, including
`PASS  .../assets/tests/run-checks.test.sh  --- 49 checks, 0 failed` and
`PASS  .../assets/tests/check-standards.test.sh  --- 94 checks, 0 failed`.

The run did not finish. After `PASS  scripts/tests/test-sh.test.sh  --- 37 checks, 0 failed`
it printed nothing more for about 10 minutes and was stopped at the session's
background time limit (about 20 minutes in all). So the file or eval test that
ran after `test-sh.test.sh` was not judged. Whoever re-runs the suite should
watch for it. It was not re-run here, because the suite is already red for the
cause above.

## Alternatives searched

- Set `GITLEAKS_ARCHIVE` to a darwin archive. This fails because the script's
  checksum pin is for the Linux archive (`check-secrets.sh:9`), so a darwin
  archive would fail as a checksum mismatch.
- Edit `check-secrets.sh` to choose the archive by platform. This fails because
  `scripts/**` is forbidden for this lane.
- Claim `[READY]` and quote the red. This fails because contract §6.4 says
  `[READY]` means a passing stamp for the head sha.

## The ask

E0.2-B1: How should this package reach `[READY]` when the local check cannot pass on macOS?
Options: (a) run `bash scripts/test.sh` on Linux or in CI at head `adaef0b` and accept that run as the stamp; (b) open a separate package to make `check-secrets.sh` platform-aware; (c) accept the macOS run with these two known-red files excepted.
Recommendation: (a) now, with (b) as follow-up work.
Decide-by: before E0.3 or the workflow package depends on E0.2.
Cost-of-waiting: E0.2 stays unmerged, and so does every package that calls `run-checks.js`.
