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

## Coordinator decision E0.3-B2 (2026-11-17)

Recorded in the #219 decisions log; #222's acceptance criteria re-cut to match.

- This PR's `standards` job is expected to fail, naming the missing base-branch `.github/standards/run-checks.js`. Quote that failure in the PR body.
- E0.2-B1 and B2 apply: the local gitleaks reds are excepted. Do not wait on a full local run; push, open the `[READY]:` PR, and stamp `VERIFIED: ci-<run id> @ <head sha>` naming the CI `Fixture tests` run at the head sha, quoting the local reds.
- The "base runner wins" throwaway PR is done by the coordinator after merge, not by this package.
- This cell's `HANDOFF.md` is the package's handoff. The `HANDOFF.md` at the repo root belongs to another package; leave it alone.

Next: open the `[READY]:` PR for the commit already pushed (a37dac3 or later) and stamp it.
