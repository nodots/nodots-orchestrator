# HANDOFF: G2.2 First evals from real incidents and skill triggers (#36)

## Done

20 cases in `evals/cases/` (plus the existing `_example.json`, not counted), and `scripts/tests/evals-cases.test.sh` (9 checks).

Incident cases, 8. Each carries `source.pr` and `source.quote`, taken verbatim from the PR body read with `gh pr view <n>`:
- `incident-pr17-sync-cells-pagination.json`
- `incident-pr17-untrusted-workspace.json`
- `incident-pr20-installed-plugin-root.json`
- `incident-pr20-orphan-not-adopted.json`
- `incident-pr21-contradicting-lane.json`
- `incident-pr21-latch-names-parked.json`
- `incident-pr22-relaunch-retry.json`
- `incident-pr23-issue-mention-claim.json`

Skill trigger cases, 10:
- `agentic-work-packages`: `trigger-awp-positive-decompose.json`, `trigger-awp-positive-issues.json`, `trigger-awp-positive-delivery-plan.json`, `trigger-awp-near-miss-single-ticket.json`, `trigger-awp-near-miss-readme.json`
- `fleet`: `trigger-fleet-positive-cycle.json`, `trigger-fleet-positive-latch.json`, `trigger-fleet-positive-dispatch.json`, `trigger-fleet-near-miss-autoscaler.json`, `trigger-fleet-near-miss-vehicles.json`

Worker contract cases, 2:
- `contract-failing-test-first.json` (checks commit order and that the test failed at the commit that added it)
- `contract-lane-blocker.json` (checks BLOCKER.md sections, forbidden file untouched, SCOPE.json not widened)

PRs 17, 20, 21, 22, 23 name more than these 8 failures or fixes (for example PR 21's skill resume path, and PR 17's project-wide fix list). I wrote one case per failure that has a testable input and left the doc-only items out. PR 17's `fleet launched a worker that could not commit` and PR 21's `latch reason names parked packages` are the thinnest: the cases test a small re-implementation of the rule, not fleet's real code. The evals measure whether a model can satisfy the rule, not whether fleet's code regressed.

## Failing test first

`bash scripts/tests/evals-cases.test.sh` against the tree with no cases: 7 of 9 checks failed (found 0 valid cases). With the 20 cases: 0 failed.

## Evals run, measured cost

Command, from the worktree root: `node evals/run.js` (model `sonnet` from `evals/budget.json`; caps $1 per eval, $25 per suite; 21 evals including `_example`).

| Run | Result | Measured suite cost |
|---|---|---|
| 1 | 20 passed, 1 failed | $1.2595 |
| 2 | 12 passed, 9 failed | $1.3297 |
| 3 | 21 passed, 0 failed | $1.2546 |

Total measured across the three runs: $3.8438. The final run, $1.2546, stayed inside the $25 suite cap. Per-eval cost in the final run: lowest $0.0368, highest $0.1045 (`contract-failing-test-first`); no eval came near the $1 cap. Monthly spend was not supplied (`--month-spent`), so the monthly ceiling was not enforced.

Run 1 failure: `contract-failing-test-first` could not run `git` under the default `acceptEdits` permission mode. Fix: `"permissionMode": "bypassPermissions"` on that case, which runs in a temp directory.

Run 2 failure, 9 evals: the runner uses one temp directory for the whole suite, not one per eval (`evals/run.js:76-79`, `workdir` passed to every `runClaude` call at `evals/run.js:44`). Run 2 was the first run where `git init` succeeded there, so the scope hook found the `SCOPE.json` that `contract-lane-blocker` had left behind and blocked every later write. Fix: each case that leaves state ends with an always-passing cleanup check (`isolation: ...`) so later evals start clean. Run 3 passed.

## Things the next session should know

- Out of lane, not fixed: `evals/README.md` says every eval runs in a fresh temp directory. The runner makes one temp directory per suite. Either the README or `evals/run.js` should change (G2.1 files, coordinator call). The cleanup checks in the two contract cases are a workaround for that.
- The trigger cases ask the model which skill it would load. They need `agentic-work-packages` and `fleet` installed in the environment that runs `claude -p`; they did here, since the positive cases passed. Near-miss cases pass vacuously when the skills are not installed, so read them only alongside the positive cases.
- `evals-cases.test.sh` checks shape only (count, schema validity via `evals/lib/cases.js`, PR and quote present, trigger counts). It does not check the quotes against the PR bodies; I did that by hand from `gh pr view`.
- Calibration input for the epic #25 budget table (coordinator applies): the measured suite cost for 21 simple evals is about $1.25 per run on sonnet, about $0.06 per eval. That is one sample set, not a distribution.
- No lint or typecheck tool exists in this repo (`scripts/test.sh` runs a syntax check over `plugins/` only).

## Plan check

Package issue still matches: yes
