# HANDOFF: V1 gate (#34)

## Done

- `scripts/tests/v1-gate.test.sh` (15 checks):
  - The stamp check (`scripts/check-stamp.js:31`, via `stamp.js:9` `currentStamp`) runs on a READY PR whose head shas come from a real temporary git repo with two commits. No stamp: flagged. A stamp on the first commit after the later push: flagged. A stamp on the head: passes.
  - `.github/workflows/stamp-check.yml:43` runs `node scripts/check-stamp.js`.
  - Approval: `approvalGate` (`plugins/fleet/src/config.js:145`) on a PR with no approval is not blocked when off (default and explicit). The same PR is blocked under `branch-protection` and `ruleset`.
- Throwaway PRs (results are in the gate PR body):
  - #72 `throwaway/v1-no-stamp`: a READY PR with no stamp.
  - #73 `throwaway/v1-stale-stamp`: stamped at `db64a74…`, then pushed `f688c2b…`.

## Next

- If the gate PR's description says the throwaway PRs are still open, close them unmerged and delete the `throwaway/v1-*` branches.
- After merge, Phase 3 is unblocked.

## Notes for a cold session

- PRs #72 and #73 shared head `db64a74` before the later push, so the check rollup for that sha mixed runs from both PRs. The stale-stamp result is read from the rollup for `f688c2b`, which only #73 had while it was being checked.
- `issue_comment`-triggered stamp runs do not appear in a PR's head-sha check rollup.
- `gh pr checks`, `gh run list` and `gh api .../actions/runs/...` were denied in the worker session. Results were read with `gh pr view --json statusCheckRollup`.

## Plan check

Package issue still matches: yes
