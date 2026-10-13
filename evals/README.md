# Evals

Non-interactive evals run through `claude -p`, under a budget the runner enforces.

```
node evals/run.js [--cases evals/cases] [--budget evals/budget.json] [--results out.json]
                  [--workdir <dir>] [--claude claude] [--month-spent USD]
```

Each case in `--cases` is one `*.json` file (format: `schema.json`, example: `cases/_example.json`): a prompt plus checks of kind `tests`, `lint` or `policy`. A check is a shell `command` that must exit 0, and/or a regex the reply must match (`resultMatches`) or must not match (`resultNotMatches`).

Every eval runs in a fresh temp directory unless `--workdir` is given, so it does not edit this repo or trip its scope hook. `--claude` may carry leading arguments (`"bash stub.sh"`).

## Budget

Caps come from `budget.json`: `perEvalUsd`, `perSuiteUsd`, `monthlyCeilingUsd`. They are proposed estimates (epic #25), not measurements.

- Each eval gets `--max-budget-usd` equal to the per-eval cap, or what the suite has left if that is smaller.
- An eval whose reported cost exceeds its budget fails, and the output shows spent versus cap.
- When the suite cap, or the monthly ceiling, is reached, the runner stops, prints spent, cap and the evals not run, and exits 1. Evals not run count as not passed and never print `PASS`.
- The monthly ceiling is enforced only when the caller passes `--month-spent`. Without it the output says monthly spend is unknown.
- Cost is read from claude's JSON output. A cost it cannot read prints as `unknown` and is stored as `null`, never zero. For the caps, an unreadable cost is counted at the per-eval cap and the output labels that figure a worst case, not a measurement.

Exit codes: 0 all passed; 1 an eval failed or did not run; 2 bad input (missing or malformed budget, no cases, malformed case).

## Tests

`bash scripts/tests/evals-runner.test.sh` runs the runner against the stub in `tests/stubs/claude.sh`. No model is called.
