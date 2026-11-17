# HANDOFF: C0.4 — the scope hooks measure a lane from its baseBranch

Stopped on `BLOCKER.md` next to this file: the `.claude/hooks/` copies could not
be written from the worker session. Everything else is done.

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

## Next
- Sync `.claude/hooks/{enforce-scope,require-handoff}.js` from
  `plugins/agentic-work-packages/hooks/`, commit, then run `bash scripts/test.sh`.
  It fails today only on those two copy checks.
- Then post the VERIFIED stamp and open `[READY]: C0.4` against `development`
  with `Closes #216`.

## Plan check

Package issue still matches: yes
