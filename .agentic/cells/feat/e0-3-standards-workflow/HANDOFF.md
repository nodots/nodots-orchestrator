# HANDOFF: E0.3 — the standards workflow and runner

## Done
- `scripts/tests/test-sh.test.sh`: fixture now carries the three assets and installed copies; new cases for a matching, differing and missing copy of each. Written first; failed 15 checks before `scripts/test.sh` changed.
- `scripts/test.sh`: copy check for `.github/workflows/standards-checks.yml`, `.github/standards/run-checks.js`, `.github/standards/check-standards.js` against their assets.
- Asset `assets/workflows/standards-checks.yml` and its installed copy; installed runner and validator copies (decision E0.3-B1).
- `references/standards.md`: Readers row and section "Running the checks in CI".

## Next
- Review and merge. On this PR the `standards` job reads the base branch's runner, and `development` does not have it yet, so it fails naming the missing file until this merges. The throwaway-PR acceptance check (edit `.github/standards/run-checks.js` to exit 0) can only run after the merge.

## Plan check

Package issue still matches: yes
