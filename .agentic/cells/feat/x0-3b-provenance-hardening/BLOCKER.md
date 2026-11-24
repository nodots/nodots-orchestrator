# BLOCKER: X0.3b — `bash scripts/test.sh` cannot pass on this worker's host (darwin): pinned linux-x64 gitleaks

**Bucket:** on a missing capability
**Kind:** human-decision
**Reference:** `scripts/check-secrets.sh:31` (`PINNED_ARCHIVE=gitleaks_8.30.1_linux_x64.tar.gz`), `scripts/check-secrets.sh:93`; `.github/workflows/ci.yml`
**Owner:** coordinator
**Un-blocks when:** `bash scripts/test.sh` prints `ALL PASS` at this branch's head on a Linux-x86_64 host (CI, or a coordinator run), and that run is stamped on the PR

## What was needed, and why
The worker contract (§6.2) requires every `checks[]` command to pass before `[READY]`. Run on this host (Darwin, arm64) at head `feat/x0-3b-provenance-hardening`, `bash scripts/test.sh` ends `FAILED`. Three suites fail, all for one reason:

- `scripts/tests/check-secrets.test.sh`: 20 checks, 4 failed
- `scripts/tests/gate-h-hardening.test.sh`: 27 checks, 3 failed
- `scripts/tests/v0-gate.test.sh`: 11 checks, 2 failed (it runs `test.sh` on a clean copy, which hits the same two suites)

Each failure reads `check-secrets.sh: line 93: …/gitleaks: cannot execute binary file: Exec format error`. The script pins and SHA-checks the linux-x64 gitleaks archive, which cannot execute on darwin. This package's diff touches none of these files. Every other suite passes, including all of `plugins/fleet/tests/` (`provenance.test.sh` 90/0, `config.test.sh` 34/0, `verify-stage.test.sh` 90/0) and the eval tests. The red is deterministic, so it gets no re-run (§5).

## Alternatives searched
- Point `GITLEAKS_ARCHIVE` at a darwin build. Fails: the SHA-256 pin rejects any other archive (`check-secrets.test.sh` asserts exactly that).
- Change `scripts/check-secrets.sh` or its tests to choose a binary per platform. Fails: `scripts/**` is in this lane's `forbiddenPaths`.
- Run the suite in a local Linux container. Fails: `docker` is not permitted in this session (the command was denied).
- Stamp a partial run. Fails: a stamp must quote the check's real summary, and that summary is `FAILED`.

## The ask
X0.3b-B1: How does a darwin worker satisfy `bash scripts/test.sh`? Options: (a) the coordinator (or CI on ubuntu) runs it at this head and stamps; (b) a follow-up package makes `check-secrets.sh` skip or select per platform, with the skip stated in its output. Recommendation: (a) now, (b) as a follow-up. decide-by: the next coordinator cycle. cost-of-waiting: X0.3b's PR stays draft and unmerged. Nothing else depends on it in Phase 0.
