# HANDOFF: G2.1 Eval harness with enforced budget (#35)

## Done

- `evals/run.js` runner, `evals/lib/{budget,cases,exec}.js`, `evals/budget.json`, `evals/schema.json`, `evals/README.md`, `evals/cases/_example.json`, `evals/tests/stubs/claude.sh`.
- `scripts/tests/evals-runner.test.sh`, 47 checks. Written first: against the tree with no runner it failed 36 of 47 checks. Now 0 failed. `bash scripts/test.sh` ends `ALL PASS`.
- Acceptance criteria and where each is tested (test labels in `scripts/tests/evals-runner.test.sh`):
  - per-eval cap exceeded: exit 1, spent versus cap printed (section 3)
  - per-suite cap reached: exit 1, unrun evals listed (section 5)
  - unrun eval never `PASS`, results file says `not-run` (section 5)
  - unreadable cost prints `unknown`, stored as `null`, never `$0.0000` (section 6); counted at the per-eval cap for budgeting and labeled a worst case (section 7)
  - monthly ceiling enforced when `--month-spent` is passed (section 8); without it the output says monthly spend is unknown

## Real run

Command, from the worktree root: `node evals/run.js` (case `evals/cases/_example.json`, model `sonnet` from `evals/budget.json`, caps $1 per eval and $25 per suite).

| Run | Result | Measured cost |
|---|---|---|
| 1 | FAIL | $0.0614 |
| 2 | FAIL | $0.0210 |
| 3 | PASS | $0.1035 |

Runs 1 and 2 ran with the work directory set to the worktree, where the scope hook blocked the write of `hello.txt` (claude's reply, printed by run 2: the write was outside `allowedPaths`). I changed the runner to default to a fresh temp directory (`evals/run.js`, `runSuite`), and run 3 passed. Run 2 was a diagnosis run, made after adding the reply excerpt to the failure output.

Total measured across the three runs: $0.1859. The final run stayed inside the $25 suite cap ($0.1035 spent). The suite had one eval, so no per-eval distribution exists.

## Proposed edit to the Eval budget table in epic #25 (coordinator applies)

- Per-eval cap row, Basis: "Measured once: one trivial eval (create a file, reply `done`, sonnet) cost $0.1035 on 2026-10-12. Failed attempts cost $0.0210 and $0.0614. One sample of one trivial eval does not support the $1 figure in either direction; keep $1 until G2.2 evals exist."
- Eval count row: "Not measured. Only `_example` exists."
- Per-suite and monthly ceiling rows: unchanged, still estimates. Nothing measured bears on them.
- Calibration rule: G2.1 ran the suite once, and it holds one eval. G2.2 should repeat the calibration with the real cases before G2.3 enables a schedule.

## Notes

- `chmod +x` on the stub and runner was denied in this session, so `evals/tests/stubs/claude.sh` and `evals/run.js` are committed without the exec bit. `--claude` accepts a command with leading arguments, and the test passes `"bash <stub>"`. Run the runner as `node evals/run.js`.
- No lint or typecheck tool exists in this repo. The syntax check in `scripts/test.sh` covers `plugins/` only, so `evals/*.js` is exercised by the fixture test and `node --check evals/run.js` (clean).
- Not done, out of lane: no CI wiring (G2.3), no real cases (G2.2).

## Plan check

Package issue still matches: yes
