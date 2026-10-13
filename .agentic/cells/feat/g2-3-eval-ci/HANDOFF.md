# HANDOFF: G2.3 Eval CI wiring, pass-rate gate, and monthly ceiling (#37)

## Done

- `.github/workflows/evals.yml`: runs on `pull_request` for `CLAUDE.md`, `**/SKILL.md`, `plugins/**/hooks/**`, `**/assets/worker-contract.md`. Steps: Monthly ceiling check, Run evals (`continue-on-error`, the gate decides), Upload results, Pass-rate gate.
- Schedule is absent. The header says why (G2.1 calibration amendment to epic #25 not merged) and gives the cron block to add afterwards.
- `evals/baseline.json`: `passRate: null`. Stored in git so raising or lowering it is a reviewed change and a run cannot lower its own bar. While null, the gate requires 100% pass. Not-run evals count as not passed.
- `evals/spend.json`: `runs: []`, entries `{date, usd}`. The ceiling step sums the current UTC month against `monthlyCeilingUsd` in `evals/budget.json`, fails at or above it, and hands the sum to `evals/run.js --month-spent`.
- `scripts/tests/evals-ci.test.sh` (37 checks). It extracts the ceiling and gate steps from the workflow and runs them against fixtures: below baseline fails, at ceiling fails loudly, unreadable ledger or results fail closed.

## Failing test first

Before the workflow existed: 3 of 3 checks failed, and the script stopped. After: 37 checks, 0 failed.

## Not verified

- The workflow has not run on GitHub. The first PR run is the first real execution. It needs the `ANTHROPIC_API_KEY` repo secret, which I did not check exists.
- YAML was not parsed by a YAML parser (the command was denied). The test extracts steps with awk, which assumes the layout in the file.
- `npm install -g @anthropic-ai/claude-code` and the `claude` binary name are taken from the runner's `--claude claude` default, not checked against the registry.
- No lint or typecheck tool exists in this repo (`scripts/test.sh` parses syntax only).

## Things the next session should know

- `passRate: null` is a decision the package did not answer. No measured baseline exists, so I did not invent one. G2.2 recorded a final run of 21 of 21 passed, which a coordinator could record as the baseline.
- `spend.json` is empty. G2.2 reports $3.8438 measured across three runs; I did not enter it, because the ledger format and who records spend are coordinator calls. The workflow never pushes, so recording each run's spend is a manual committed edit. Automating it needs a path outside this lane.
- The ceiling check applies to pull-request runs too, not only scheduled ones. The runner would stop at the ceiling anyway.
- The path filter does not include `evals/**`, so a baseline edit alone does not trigger a run.

## Plan check

Package issue still matches: yes
