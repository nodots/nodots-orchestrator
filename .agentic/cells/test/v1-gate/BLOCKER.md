# BLOCKER: V1 — throwaway PRs #72 and #73 cannot be closed from the worker session

**Bucket:** blocked on a missing capability
**Kind:** human-decision
**Reference:** nodots/nodots-orchestrator#72, #73; the worker session's permission settings
**Owner:** coordinator (Ken Riley)
**Un-blocks when:** PRs #72 and #73 show state CLOSED, not merged.

## What was needed, and why

Acceptance criterion: "Throwaway PR results are linked in the gate PR; PRs closed unmerged." Both throwaway PRs are open and their results are recorded. Closing them was denied:

- `gh pr close 72 --repo nodots/nodots-orchestrator --delete-branch --comment "..."` — denied
- `gh pr close 73 --repo nodots/nodots-orchestrator --delete-branch --comment "..."` — denied
- `gh pr close 72 --repo nodots/nodots-orchestrator` — denied

These were also denied, so the per-run details were read from `gh pr view --json statusCheckRollup` instead: `gh pr checks 73 ...`, `gh run list ...`, `gh api repos/.../actions/runs/<id>`.

## Results recorded

| Case | PR | Head | Stamp check |
|---|---|---|---|
| No stamp | #72 (`throwaway/v1-no-stamp`) | `0f31eaf0596d3e97ace1afa1149f71f79ea965b3` | FAILURE — https://github.com/nodots/nodots-orchestrator/actions/runs/38331121755/job/115080849338 |
| Stale stamp: stamp names `db64a746ba108c6814617fba7e449f342897fb03`, then a later push | #73 (`throwaway/v1-stale-stamp`) | `f688c2b831b45ed5e40d167e2d9a39fa0720e6b4` | FAILURE — https://github.com/nodots/nodots-orchestrator/actions/runs/38331074072/job/115080697015 |

Each head sha above was on exactly one PR when its check ran. Earlier, both PRs shared `db64a74`, and the check rollup for that sha mixed one FAILURE and one SUCCESS that could not be attributed to a PR. Those runs are not used as evidence.

Done otherwise: `scripts/tests/v1-gate.test.sh` (15 checks) passes. The local `bash scripts/test.sh` ended with `ALL PASS`. The gate PR has not been opened yet.

## Alternatives searched

- Leave #72 and #73 open and open the gate PR — this fails the criterion "PRs closed unmerged", and the coordinator note on #34 says to stop on a denied command.
- Close them through `gh api -X PATCH repos/.../pulls/<n>` — this routes around the same denied permission, which the contract forbids.

## The ask

V1-1: Close #72 and #73 unmerged and delete branches `throwaway/v1-no-stamp` and `throwaway/v1-stale-stamp`, or allow `gh pr close` for the worker. Then remove this file and open the gate PR (`[READY]: V1 ...`, "Closes #34", body linking #72 and #73 with the table above), and stamp it. Recommendation: the coordinator closes both PRs, as it did for V0. Decide by: the next coordination cycle. Cost of waiting: Phase 3 stays blocked on this gate.
