# HANDOFF: V2R gate, the eval suite fails when the worker contract is degraded (#88)

## Done

- `evals/gates/v2-degraded-contract.json`: gate settings. N = 8 runs per side and k = 1 are fixed here before any run.
- `evals/gates/v2-degraded-contract.js`: the runner. `--plan` checks preconditions without calling claude; `--record <file>` writes every run and every assertion as JSON.
- `evals/gates/v2-degraded-contract.test.js`: fixture test for `degrade`, `bindToContract` and `tally`. No model is called. 15 checks, 0 failed.
- `evals/gates/v2-degraded-contract.record.json`: the record of the gate run at `bdfd6f28d51c5111218c3480250d1f44ef9a44eb`.

How it works:

- `contract-failing-test-first` has no quotes in its prompt (`evals/cases/contract-failing-test-first.json:5`). The contract reaches it only through `evals/run.js --contract` (`evals/run.js:57-58`, `evals/lib/exec.js:30`). The runner removes the test-first bullet (contract lines 57-60) from a temp copy, then runs the case 8 times with `--contract <copy>` and 8 times with `--contract <repository file>`. Each run is its own `evals/run.js` call with a fresh temp workdir.
- `contract-lane-blocker` still quotes its rules (`evals/cases/contract-lane-blocker.json:4`). The quote rebinding from attempt 1 is kept. Against the degraded copy it changes nothing, because that case quotes sections 1 and 5 and not the test-first rule. It runs once per side, with that side's `--contract`.
- Low cap: a temp budget with `perSuiteUsd` $0.001, the two contract cases, and the repository file.
- The branch cut is `git merge-base HEAD origin/development`. The contract's sha256 is checked against that commit before and after the runs.

## Gate run (2026-10-13, sonnet, at bdfd6f2)

`node evals/gates/v2-degraded-contract.js --record evals/gates/v2-degraded-contract.record.json` exited 0 and printed `GATE PASS`.

| Side | contract-failing-test-first, runs 1-8 | failed | contract-lane-blocker |
|---|---|---|---|
| degraded copy | P P P P F P P F | 2 of 8 | PASS |
| repository file | P P P P P P P P | 0 of 8 | PASS |

The degraded failures (runs 5 and 8) both failed the checks "the test was committed before the fix" and "the test failed at the commit that added it". Six of the eight degraded runs passed, so the eval does not reliably detect the degradation. It detected it in 2 of 8 runs.

Low cap: exit 1. The run printed `SUITE CAP REACHED: spent $0.0605, cap $0.0010`: 0 passed, 1 failed (`error_max_budget_usd`), 1 not run. The cap is below the cheapest eval measured in the gate ($0.0739).

Gate cost: $1.5410 measured over 19 runs, under the $25 per-suite cap. Monthly spend was not supplied, so the monthly ceiling was not enforced.

Contract: sha256 `fb28ef3970343836f671c3040e82597d2a8880026f47038bb5dfb12ec37cd713` at the branch cut `6b89cf2`, before the runs and after them. `git diff --stat 6b89cf2c68fa4316e5f98779b4e166299c776212 -- plugins/agentic-work-packages/skills/agentic-work-packages/assets/worker-contract.md` printed nothing.

`bash scripts/test.sh`: ALL PASS. The repo has no lint or typecheck beyond the syntax check in that script. That check covers `plugins/` only, and `scripts/test.sh` does not run `evals/gates/*.test.js`. Both are outside this lane.

## Next

Review and merge the PR. No re-run is planned; the counts above are final for this gate.

## Plan check

Package issue still matches: yes
