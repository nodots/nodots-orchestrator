# HANDOFF: K0.6 — adoption commits and pushes the lane; prompt names the in-repo contract

## Done

- `plugins/fleet/src/launch.js`, `prepareWorktree` adoption branch: after the lane check, a lane file that is untracked is committed as `<ID>: scope`, and one that differs from `HEAD` as `<ID>: scope re-cut` (pathspec commit, only the lane). A `git add` failure (for example an ignored `.agentic/`) is `launch-commit` and starts no worker. The branch is pushed with a plain `git push -u origin <branch>` when it does not track `origin/<branch>` or is ahead of it; a rejected push is stage `claim`. No force anywhere.
- `buildPrompt` names `.claude/worker-contract.md in this worktree` when the worktree has that file, and `cfg.contractPath` otherwise. Without a `worktree` argument the prompt is byte-identical to before (`verify-config.test.sh` D still passes).
- `plugins/fleet/tests/adoption.test.sh` (new, 32 checks): replays the incident (first launch fails at `git add` because `.agentic/` is ignored; adoption while still ignored fails at the commit; after the ignore is removed, the next applied cycle commits the lane and pushes the branch to the worktree's head), the already-pushed case (git stub log shows no commit and no push), the rejected-push case (`launch-claim`, no worker), and both prompt variants from the claude stub's argv. It failed 11 of 31 checks against the pre-change `launch.js`.
- `bash scripts/test.sh` ends `ALL PASS`.

## Notes for a cold session

- The recut path's push failure used to be `launch-push`; on adoption it is now `launch-claim`, as the package specifies. `plugins/fleet/skills/fleet/SKILL.md` (outside this lane) still describes `launch-push` as the plain-push rejection, which remains true for the new-worktree path.
- Not changed (out of scope): a branch behind its upstream is adopted without a pull, as before; and an ignored `.agentic/` still fails both launch paths at the commit, loudly.
- This worker's own read of the plugin-cache contract path was refused, the defect this package fixes; it followed `.claude/worker-contract.md` in the worktree.

## Plan check

Package issue still matches: yes
