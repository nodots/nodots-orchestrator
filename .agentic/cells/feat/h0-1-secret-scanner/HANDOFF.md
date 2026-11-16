# HANDOFF: H0.1 pinned secret scanner

## Done
- `scripts/tests/check-secrets.test.sh`: written first; 12 of 20 checks failed on the pre-change tree (script absent).
- `scripts/check-secrets.sh <base> <head>`: pins gitleaks 8.30.1 and the SHA-256 from `gitleaks_8.30.1_checksums.txt` (coordinator, decision H0.1-net). Uses `GITLEAKS_ARCHIVE` when set (a missing path fails, no download fallback). A mismatch exits 1 before extraction. Runs `gitleaks git --redact --log-opts=<base>..<head>` with `.gitleaks.toml`; prints commit, file, rule from the JSON report only.
- `.gitleaks.toml`: `useDefault = true`, no allowlist entries (full-history scan at `e17cbd6`: 0 findings; fixtures build fake keys at runtime).
- `.github/workflows/ci.yml`: new `pull_request`-only step with the PR base and head shas; existing steps unchanged.
- `working-agreements.md`: section "Two secret checks, two scopes".
- In this session the test's one-shot `curl` download of the archive succeeded, so the scan checks ran (20/20). `bash scripts/check-secrets.sh origin/development HEAD` passed over this branch's 5 commits.

## Next
- Review and merge. `ci.yml` is also in I0.2's lane (#180); the later PR merges `development`.

## Cold-session notes
- The test skips the scan checks only when there is no `GITLEAKS_ARCHIVE` file and the download fails; the tally line then reads `scan checks skipped: <reason>`.
- `/srv/fleet-worktrees/cache/` is outside this session's sandbox; it could not be read here.

## Plan check

Package issue still matches: yes
