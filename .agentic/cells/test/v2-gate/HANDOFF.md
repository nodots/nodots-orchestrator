# HANDOFF: V2 gate, the eval suite fails when the worker contract is degraded (#39)

## Done

- `evals/gates/v2-degraded-contract.json`: the gate definition (contract path, base ref, the two contract cases, the bullet to remove, the low cap, and the expected outcome of each run).
- `evals/gates/v2-degraded-contract.js`: runs the gate. `node evals/gates/v2-degraded-contract.js` runs all three suites; `--plan` checks the preconditions without calling claude.

How it works:

- The contract cases do not read `worker-contract.md`; they quote it in their prompts (`evals/cases/contract-failing-test-first.json:5`, `evals/cases/contract-lane-blocker.json:4`). So the gate rebinds the quotes to a copy of the contract: a quoted sentence that is in the repository file but missing from the copy is dropped from the prompt (`bindToContract`).
- The degraded copy is written to a temp directory with the test-first bullet removed (asset contract lines 57-60). The repository file is only read. Its sha256 is checked against `origin/development` before and after the runs.
- Against the real file the rebound cases are byte-identical to the committed cases. The gate asserts this, so the real run is the committed evals.
- `evals/run.js` runs unmodified, three times: degraded, real, and real with `perSuiteUsd` set to `$0.001` in a temp copy of `evals/budget.json`. The gate asserts that the low cap is below the cheapest eval measured in the real run.

## Status: blocked, see `BLOCKER.md`

The gate ran twice on the same tree. Run 1 passed. Run 2, at 233b8ba, failed: the degraded `contract-failing-test-first` eval passed ($0.2018 suite, $0.4422 gate total), so the degraded run exited 0. Every other assertion held. No `VERIFIED:` stamp is posted on PR #85.

## Gate run 1 (2026-10-13, sonnet, from the worktree root)

`node evals/gates/v2-degraded-contract.js`, exit 0, `GATE PASS`.

| Run | Result | Measured cost |
|---|---|---|
| degraded | exit 1; `contract-failing-test-first` FAIL (test not committed before the fix; test did not fail at its commit), `contract-lane-blocker` PASS | $0.2381 |
| real | exit 0; 2 of 2 passed | $0.1909 |
| low cap ($0.0010) | exit 1; `SUITE CAP REACHED: spent $0.0452, cap $0.0010`; 0 passed, 1 failed, 1 not run | $0.0452 |

Gate total: $0.4743 measured, under the $25 per-suite cap. Monthly spend was not supplied, so the monthly ceiling was not enforced.

`git diff --stat origin/development -- plugins/agentic-work-packages/skills/agentic-work-packages/assets/worker-contract.md` printed nothing; sha256 `fb28ef3970343836f671c3040e82597d2a8880026f47038bb5dfb12ec37cd713` before and after.

`bash scripts/test.sh`: ALL PASS. The repo has no lint or typecheck tool beyond the syntax check in that script, and that check covers `plugins/` only, not `evals/gates/`.

## Things the next session should know

- The degraded failure is not stable: 1 of 2 degraded runs failed. The decision on how to proceed is V2-1 in `BLOCKER.md`.
- Interpretation to confirm: the package says to run the evals "against the degraded copy". Because the cases quote the contract, not read it, the gate binds the quoted text to the copy. Having the cases read the contract file instead would be a change to `evals/cases/**`, which this lane forbids.
- `git hash-object` was denied by worker permissions, so the base hash is computed in the gate script from `git show origin/development:<path>`.
- The gate is not wired into `scripts/test.sh` or CI (both out of lane). It calls the model and costs about $0.50 a run.

## Next

A decision on V2-1 (`BLOCKER.md`), then a re-run of the gate and a `VERIFIED:` stamp on PR #85.

## Plan check

Package issue still matches: yes
