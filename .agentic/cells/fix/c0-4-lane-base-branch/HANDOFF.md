# HANDOFF: C0.4 — the scope hooks measure a lane from its baseBranch

The worker stopped on a BLOCKER.md: the `.claude/hooks/` copies could not be
written from the worker session. The coordinator synced them and removed the
BLOCKER (decision C0.4-copies on #189).

## Done
- Failing tests first. Against the pre-change tree: `require-handoff.test.sh`
  7 failed (the #215 reproduction among them), `enforce-scope.test.sh` 2,
  `scope.test.sh` 5, `integration-branch.test.sh` 11. After the change all four
  pass: 81, 58, 30 and 71 checks, 0 failed.
- Hooks (`plugins/agentic-work-packages/hooks/`, copied byte-identical to
  `assets/hooks/`): `laneMergeBase(root, branch, baseBranch)` takes the merge
  base against `origin/<baseBranch>`, then `refs/heads/<baseBranch>`, then falls
  back to the nearest-of-`LANE_BASES` rule. `laneViolations` passes
  `scope.baseBranch`, so the Stop, TaskCompleted and PostToolUse Bash checks all
  use it. `require-handoff.js` `namedAsBase` exempts a branch that any
  `.agentic/cells/**/SCOPE.json` names as its `baseBranch`.
- `scope.js` `validate`: `baseBranch [x] is unsafe` when present and not a safe
  branch name.
- `launch.js`: `laneScope(target, sc)` adds `baseBranch: <integrationBranch>`.
  Both the new-worktree write and the re-cut path use it. `launch()` refuses
  `scope-base-mismatch`, naming both branches, before anything is created, when
  an issue block names a different `baseBranch` on a target with
  `integrationBranch`. A target without `integrationBranch` writes SCOPE.json as
  before.
- `scope-contract.md` documents the field and the merge-base rule. `cell.md`
  adds it to the SCOPE block.

- Attempt 2: the three hook copies are byte-identical (`cmp`).
  `bash scripts/test.sh` ends `ALL PASS`, 64 test files, 0 failed.

## Next
- Open `[READY]: C0.4` against `development` with `Closes #216`, then post the
  VERIFIED stamp for the pushed head.
- After that, only review and merge.

## Plan check

Package issue still matches: yes
