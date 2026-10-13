# HANDOFF: V1 gate (#34)

## Done

- `scripts/tests/v1-gate.test.sh` (15 checks):
  - The stamp check (`scripts/check-stamp.js:31`, via `stamp.js:9` `currentStamp`) runs on a READY PR whose head shas come from a real temporary git repo with two commits. No stamp: flagged. A stamp on the first commit after the later push: flagged. A stamp on the head: passes.
  - `.github/workflows/stamp-check.yml:43` runs `node scripts/check-stamp.js`.
  - Approval: `approvalGate` (`plugins/fleet/src/config.js:145`) on a PR with no approval is not blocked when off (default and explicit). The same PR is blocked under `branch-protection` and `ruleset`.
- Throwaway PRs, both flagged by the Stamp check (the table and run links are in `BLOCKER.md`):
  - #72 `throwaway/v1-no-stamp`, head `0f31eaf`: no stamp → FAILURE.
  - #73 `throwaway/v1-stale-stamp`: stamped at `db64a74`, then pushed `f688c2b` → FAILURE.
- Local `bash scripts/test.sh`: ALL PASS (v1-gate 15 checks, v0-gate 11 checks).

## Next

- Blocked: closing #72 and #73 was denied in the worker session. See `BLOCKER.md`.
- Once both are closed unmerged: remove `BLOCKER.md`, open the gate PR (`[READY]: V1 ...`, "Closes #34", linking #72 and #73), run `bash scripts/test.sh` on its head, and post the `VERIFIED:` stamp.

## Notes for a cold session

- PRs #72 and #73 shared head `db64a74` at first, so that sha's check rollup mixed runs from both PRs. Each was then pushed to a head of its own (`0f31eaf` for #72, `f688c2b` for #73), and the results come from those heads only. `0f31eaf` is the handoff commit on this branch, and this branch's head has since moved past it.
- `issue_comment`-triggered stamp runs do not appear in a PR's head-sha check rollup.
- `gh pr checks`, `gh run list` and `gh api .../actions/runs/...` were denied in the worker session. Results were read with `gh pr view --json statusCheckRollup`.

## Plan check

Package issue still matches: yes
