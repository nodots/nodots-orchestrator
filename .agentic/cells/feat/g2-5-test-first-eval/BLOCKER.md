# BLOCKER: G2.5 — the runner never gives the contract to the model; a prompt-only edit leaves the contract with no path to the model

**Bucket:** on a decision
**Kind:** human-decision
**Reference:** nodots/nodots-orchestrator#86 (this package), #39 (V2 gate, PR #85), decision V2-1
**Owner:** coordinator / package author (nodots)
**Un-blocks when:** #86 is edited to say how the contract reaches the model, or its lane is widened to cover that mechanism

## What was needed, and why

The package requires the test-first rule to reach the model "only through the contract, not through the prompt", by editing only the `prompt` of `evals/cases/contract-failing-test-first.json`.

Read from the files:

- `evals/run.js:41-44` passes `c.prompt` to `runClaude` and nothing else. No contract text, file path, or system-prompt argument is supplied.
- `evals/lib/exec.js:26-33` builds `claude -p <prompt> --output-format json ... --permission-mode ... --no-session-persistence [--model]`, with `cwd: workdir`. No `--append-system-prompt` or equivalent.
- `evals/run.js:75-77` makes `workdir` a fresh temp directory (`fs.mkdtempSync(path.join(os.tmpdir(), 'evals-'))`) unless `--workdir` is given. A temp directory has no `CLAUDE.md` and no `.claude/worker-contract.md`, so the repo's `@.claude/worker-contract.md` import (the install route in the contract's last section) does not apply.
- Per PR #85's body, the V2 gate works by rebinding the quoted contract text in the case prompts to a temp copy. That is the only route by which "the contract" reaches the model today.

So the prompt is the only channel. Removing the quoted rule from the prompt, as the package requires, leaves the model with no contract at all, against both the real contract and the degraded copy. The real-contract runs would then test an uninstructed model, and the "3 of 3 pass against the real contract" criterion would depend on model habit, not on the contract. I have not run any eval, so I do not know the pass rate.

Not verified: that the prompt quote and commit wording explain the flip in V2 (the issue also says this is unverified).

## Alternatives searched

- Prompt tells the model to read a contract file by path — a relative path does not resolve from the temp workdir. An absolute path ties the committed case to one machine's checkout, and the V2 gate's rebinding (which swaps quoted text, not paths) would not point the degraded run at the copy. Measuring the degraded copy would need a separate temp case with a different path, so the committed case and the measured case would differ.
- Pass `--workdir` pointing at a directory containing a `CLAUDE.md` that imports the contract — the case file cannot set the workdir; that is a runner flag (`evals/run.js:25`), and `evals/run.js` is read-only for this package. It would also need the contract copied into that directory, which is a harness/gate change (`evals/gates/**` is forbidden).
- Add a field to the case (for example a contract path) that the runner turns into a system prompt — needs a change to `evals/run.js`, `evals/lib/**` and likely `evals/schema.json`, all outside `allowedPaths`.
- Keep the quote but remove only the order hints (commit-after-each-step, "regression test") — this does not meet the package's own acceptance criterion that the prompt no longer quotes the rule, and the quote is the likelier of the two features to carry the rule. This also keeps the gate comparison dependent on the prompt, not the contract.

## The ask

G2.5-1: How should the contract reach the model in this eval? Options: (a) widen the lane to the runner/gate so the contract is supplied as a system prompt or workdir `CLAUDE.md` and the prompt carries only the task; (b) keep the prompt as the only channel and accept a path-reference prompt with an absolute path, measuring the degraded copy through a temp case; (c) drop the quote only and keep the order hints removed, then state in the PR that the contract is still delivered via the prompt. : recommendation (a), because it is the only option where the eval's result depends on the contract file, which is what V2-1 needs to show : decide-by the next coordinator cycle : cost-of-waiting #39 (V2 gate) stays blocked on this package.
