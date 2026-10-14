# HANDOFF: G2.5 test-first eval depends on the contract

## Done
- `evals/run.js --contract <file>`: the file's text goes to claude as `--append-system-prompt` for every case (`evals/lib/exec.js` `runClaude`, `systemPrompt`). Without the option the argv is unchanged. An unreadable or empty file exits 2 before any eval runs.
- Mechanism chosen from `claude --help` on the installed CLI, which lists `--append-system-prompt <prompt>`. `--append-system-prompt-file` is named only inside the `--bare` description, not as its own option, so it was not used. `claude --version` was denied by the session's permissions, so the version is not recorded.
- Test: `node evals/tests/contract-option.test.js`. It is 13 checks, and 5 failed against the pre-change runner. It is node, not bash, because `bash evals/tests/...` is denied by `.claude/settings.json` (only `bash scripts/*`, `bash plugins/*` and `node` are allowed).
- `evals/cases/contract-failing-test-first.json` prompt: task only, no rule quote, no order hint, no "regression test", plus "Commit your work as you go." `id`, `source`, `permissionMode` and `checks` are unchanged.
- Measured (sonnet, run counts fixed at 3 + 3 before the first run, all six run concurrently, each in its own temp workdir):

| Run | Contract | Result | Cost |
|---|---|---|---|
| real-1 | real | PASS | $0.1264 |
| real-2 | real | PASS | $0.0875 |
| real-3 | real | PASS | $0.0793 |
| degraded-1 | copy without the test-first bullet | PASS | $0.0857 |
| degraded-2 | copy without the test-first bullet | PASS | $0.0801 |
| degraded-3 | copy without the test-first bullet | FAIL (test committed with or after the fix; test did not fail at its commit) | $0.0788 |

  The total is $0.5378, measured, under the $25 per-suite cap. Real: 3 of 3 passed. Degraded: 1 of 3 failed.
- The degraded copy removes only the section 4 bullet "Write the failing test before the change. ... not a licence to proceed." Its sha256 is `c316d950…a7111`. Real contract sha256 `fb28ef39…cd713` before and after the runs. `git diff --stat origin/development` on both contract files printed nothing.

## Next
- #39 must change `evals/gates/**`: run the degraded suite with `--contract <temp copy>` and the real suite with `--contract <repo worker-contract.md>`. The quote rebinding no longer reaches this case, because its prompt carries no quote. `contract-lane-blocker` still quotes its rule in its prompt, so rebinding still applies to that case until it is moved to `--contract` as well.
- The degraded failure count is below 3 of 3, so V2-1 option (b) applies next (N and k set on #39).
- `evals/tests/contract-option.test.js` is not run by `scripts/test.sh`, which globs only `scripts/tests`, `plugins/fleet/tests` and the assets tests. Wiring it in needs a `scripts/**` change, which is outside this lane.
- Caveat: `claude -p` in the temp workdir still loads the user's global `~/.claude/CLAUDE.md`. That applies equally to the real and degraded runs.

## Plan check

Package issue still matches: yes
