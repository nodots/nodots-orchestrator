# HANDOFF: R0.2 fleet review stage

## Done
- Attempt 1 parked on R0.1 not being merged; R0.1 merged as #194 and this
  branch merged `origin/development` (7d65e61). The repo-root `HANDOFF.md` is
  G2.4's, not this package's; left untouched.
- Attempt 2, tests first (6db1404): `plugins/fleet/tests/review-stage.test.sh`
  and `tests/stubs/reviewer.sh`. Against the tree without `src/review.js` the
  suite failed 57 of 76.
- Attempt 2, implementation:
  - `src/config.js`: `reviewers` validated (`name` regex and unique, `argv`
    non-empty strings, `timeoutMinutes` positive integer, default 20; absent is
    `[]`). `requireReviewers(cfg, policies)` throws ECONFIG naming each target
    with a review policy when `reviewers` is empty.
  - `src/review.js`: the stage. State is `state.review[<repo>]` =
    `{ inFlight: [{ pr, reviewer, headSha, issue, pid, startedAt, ... }], failed: { <pr>: { <reviewer>: { headSha, kind, reason, at } } } }`.
    Worktrees under `<worktreesDir>/.review/`, prompt and verdict under
    `<stateDir>/review/<repo>-<pr>-<reviewer>-<sha7>/`, outside the worktree.
  - `src/cycle.js`: `requireReviewers` right after the sync (alarm
    `config-invalid`, exit 64); stage 4c after verify (skipped when verify
    latched); `review-failed` requests take the `verify-failed` branch
    (same tier, counted toward `maxEscalations`); `review-*` faults except
    `review-stale` make the cycle an alarm; reviews in flight hold the streak.
  - `src/report.js`: Review section; `awaiting-reviewer` and `reviewing`
    counts only for a config with reviewers.
  - `README.md` (`## Review`) and `skills/fleet/SKILL.md` (alarms).

## Decisions made here (the package did not say)
- "A config with a review policy target and no reviewers fails validation":
  the policy lives in the target repo's manifest, which config load cannot
  read, so the check runs in the cycle once the sync has read the policy.
  It aborts the cycle like a config error (`config-invalid`, exit 64).
- A reviewer that wrote, timed out or gave invalid output at a head is
  recorded in `failed` too, so it is not relaunched at that head every cycle.
- The worked `argv` example wraps `claude -p ... --permission-mode plan` in
  `sh -c` with stdin and stdout redirection: in plan mode the model cannot
  write `{out}` itself. The brief tells a reviewer that cannot write files to
  make its final answer the JSON verdict.
- `store.js` is unchanged: `store.test.sh` pins the state key set and is
  outside the lane; `state.review` is created on demand, as `state.verify` is.

## Next
- `bash scripts/test.sh` at the head, the `[READY]: R0.2` PR against
  `development` ("Closes #175") and the VERIFIED stamp. If the PR is open,
  check that the stamp names the current head; re-run and re-stamp if not.

## Plan check

Package issue still matches: yes
