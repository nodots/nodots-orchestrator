# HANDOFF: CV gate — merge into collection/t, promote, refuse a protected base

## Done
- `plugins/fleet/tests/gate-c-merge.test.sh` drives #193's six scenarios
  through `fleet cycle --apply` over three cycles. The fixture is a bare remote
  with `development` (the default branch) and `collection/t`, one commit ahead.
  It runs the real `sync-cells.sh` and `assign-cells.sh`, with the gh and claude
  stubs unchanged.
  - Cycle 1: T1.1 is launched from `collection/t`; its prompt names
    `collection/t`. Its branch is `collection/t`, then `T1.1: scope`
    (`src/launch.js:370`), then the worker's commit. T1.2 is held waiting on
    feat/t1-1. In the same cycle the three fixture PRs are judged: #300 is held
    with `test fail` named, #301 on `development` raises
    `merge-protected-refused` with no merge attempted, and #302, whose head moved
    after its checks, fails `merge-failed` "Head branch was modified".
  - Cycle 2: T1.1's PR is merged `--merge --match-head-commit <head>` into
    `collection/t`. #300 and #301 are held and refused again. #302 is held with
    no stamp at its new head, and no second merge is attempted.
  - Between cycles 2 and 3, the suite plays GitHub's side. Only once the stub has
    logged the merge, it merges feat/t1-1 into `collection/t` with `--no-ff` on
    the remote. The gh stub flips the PR to MERGED but does not touch git.
  - Cycle 3: the sync derives `cell:merged` "(into collection/t)". T1.2 is
    promoted and launched, and its worktree's base is the merge commit, holding
    T1.1's commit and file.
- The suite also stands in for the worker's `gh pr create --base collection/t`
  by setting `baseRefName` on the stub's PR. The claude stub records no base,
  and the gh stub's `pr view` would then report `main`.
- `bash scripts/test.sh` ends ALL PASS, with gate-c-merge at 50 checks, 0 failed.

## Next
- Acceptance criterion 2, showing each scenario red against a broken `src/`, is
  not done. See `BLOCKER.md` beside this file, which lists six mutations to run
  in a scratch clone.

## Plan check

Package issue still matches: yes
