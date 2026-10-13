# BLOCKER: V2 — the degraded-contract eval failed in 1 of 2 gate runs, so the gate does not reliably detect the missing rule

**Bucket:** blocked on a decision
**Kind:** human-decision
**Reference:** nodots/nodots-orchestrator#39, PR #85, `evals/cases/contract-failing-test-first.json`
**Owner:** the coordinator / the owner of epic #25
**Un-blocks when:** a decision on V2-1 below is recorded on #39 (and, for option a, the case change has merged to `development`)

## What was needed, and why

Acceptance criterion: "Degraded copy: at least one worker-contract eval fails." The gate (`node evals/gates/v2-degraded-contract.js`) ran twice on the same tree:

| Run | Degraded `contract-failing-test-first` | Degraded `contract-lane-blocker` | Real file | Low cap | Gate |
|---|---|---|---|---|---|
| 1 (before commit, tree equal to 233b8ba) | FAIL ($0.1438) | PASS | 2 of 2 PASS | exit 1, `SUITE CAP REACHED: spent $0.0452, cap $0.0010` | PASS |
| 2 (at 233b8ba) | PASS ($0.1067) | PASS | 2 of 2 PASS | exit 1, `SUITE CAP REACHED: spent $0.0503, cap $0.0010` | FAIL |

With the test-first rule removed, sonnet still wrote the test first in run 2. Every other assertion held in both runs, and the contract file hashed `fb28ef39…cd713` before and after both runs.

A likely cause, not verified: the case prompt itself asks for an ordered history ("commit after each step so the order of the steps is in the git history", `evals/cases/contract-failing-test-first.json:5`) and calls the test a regression test, which may steer a model to test-first without the rule. `contract-lane-blocker` cannot detect this degradation at all: it does not quote the removed rule, so its prompt is the same in both sets.

## Alternatives searched

- Re-run the gate until the degraded run fails — forbidden by the worker contract (section 5: never re-run a suite until it passes). It would also hide the finding.
- Relax the degraded assertion inside the gate (for example, pass when the degraded run passes) — forbidden (never relax an assertion until it holds), and it would defeat the gate.
- Edit `contract-failing-test-first.json` so the prompt does not hint at the order — `evals/cases/**` is in `forbiddenPaths`.
- Remove more of the contract in the degraded copy — the package specifies removing the test-first rule only. Removing more would test a different degradation.
- Run the degraded suite N times inside the gate and require failures in at least k of them — this lane allows it (`evals/gates/**`), but N, k and the cost are a design decision the package does not answer, and with the current case the failure rate is unknown (1 of 2 observed).

## The ask

V2-1: How should V2 show that the eval detects the missing test-first rule, given that the degraded eval failed in 1 of 2 runs? Options: (a) a new package amends `contract-failing-test-first.json` so its prompt does not ask for an ordered history or name the test a regression test, then V2 re-runs unchanged; (b) the gate runs the degraded suite N times and requires at least k failures, with N and k set on #39 (cost is about $0.20 per degraded run); (c) accept a single-sample gate and record its flakiness. : Recommend (a), then (b) with N=3, k=2 if (a) alone does not give a stable failure : decide-by the Phase 2 close review : cost-of-waiting the Phase 2 close, which this gate blocks
