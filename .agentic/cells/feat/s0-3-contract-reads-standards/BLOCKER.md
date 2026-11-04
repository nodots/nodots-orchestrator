# BLOCKER: S0.3 — no `.claude/standards.json`, so §6 step 2 has no checks to run

**Bucket:** blocked on a missing capability
**Kind:** human-decision
**Reference:** #120, #122 (S0.5 publishes this repo's manifest), epic #117
**Owner:** coordinator
**Un-blocks when:** `.claude/standards.json` exists on `development` (S0.5 merged) and this branch is updated from it, or the coordinator records a decision naming the checks for this package on #117

## What was needed, and why

The installed contract on this branch (`.claude/worker-contract.md:127-133`, copied by the coordinator in 8b7dfdf) is the text this package introduces. Its §6 step 2 says: run every `checks[]` command in `.claude/standards.json`; if the file is absent, stop and write `BLOCKER.md` with bucket `on a missing capability`, kind `human-decision`, the coordinator as owner. The file is absent: `ls .claude/` shows `hooks settings.json worker-contract.md`, and `git show origin/development:.claude/standards.json` fails with "does not exist". S0.5 (#122) publishes it, and the coordinator runs S0.5 after S0.1 and S0.2 merge (#117 decisions log).

Everything else is done and verified at head 0e74e2f (no new commits this attempt apart from this file):

- AC1: `grep -n -iE 'lint|typecheck|npm' plugins/agentic-work-packages/skills/agentic-work-packages/assets/worker-contract.md` prints nothing.
- AC2: §6 step 2 (`assets/worker-contract.md:127-133`) names `.claude/standards.json` `checks[]`, and the absent case ends in `BLOCKER.md`.
- AC3: §3 (`assets/worker-contract.md:54-59`) names the `rules[]` docs to read and says how a `#fragment` is resolved.
- AC4: `diff plugins/agentic-work-packages/skills/agentic-work-packages/assets/worker-contract.md .claude/worker-contract.md` prints nothing.
- AC5: `plugins/agentic-work-packages/agents/cell-worker.md:14` step 1 reads the manifest.
- AC6: `bash scripts/test.sh` ends `ALL PASS`, exit 0 (last lines: `PASS scripts/tests/v3-gate.test.sh --- 71 checks, 0 failed`, `PASS evals/tests/contract-option.test.js --- 13 checks, 0 failed`, `PASS evals/gates/v2-degraded-contract.test.js --- 15 checks, 0 failed`, `ALL PASS`).

No PR is open. A `[READY]:` PR needs a `VERIFIED` stamp listing every `checks[]` entry (§6 step 4), and with no manifest there are no entries.

## Alternatives searched

- Use `bash scripts/test.sh` as the check, based on the epic's definition of done — that is a check inferred from outside the manifest. §6 step 2 says "do not infer them", and the epic says "No convention fallback".
- Write `.claude/standards.json` myself — it is outside `allowedPaths`, it is under `.claude/` (decision S0.3-1: no fleet lane includes `.claude/`), and it is S0.5's deliverable.
- Follow the pre-change contract on `development` ("Tests, build/typecheck and lint pass") — the installed copy on this branch governs this worktree, and it has replaced that line.

## The ask

S0.3-3: Which checks gate this PR? (a) wait for S0.5 to merge, merge `development` into this branch, then relaunch so the worker runs the manifest's checks, stamps and opens the PR; (b) record on #117 that S0.3's checks are `bash scripts/test.sh` (the epic's definition of done), remove this file, and relaunch so the worker stamps with that one check and opens the PR : recommend (b), because S0.5 is not dependency-ordered against S0.3 and the suite already passes : decide-by S0.1 and S0.2 merging : cost-of-waiting S0.3's PR and SV0 (#123), which gates on S0.3
