# BLOCKER: S0.3 — the installed copy `.claude/worker-contract.md` cannot be written from a worker session

**Bucket:** on a missing capability
**Kind:** human-decision
**Reference:** #120; the session's permission policy for `.claude/worker-contract.md`
**Owner:** coordinator (Ken Riley)
**Un-blocks when:** `.claude/worker-contract.md` on `feat/s0-3-contract-reads-standards` is byte-identical to `plugins/agentic-work-packages/skills/agentic-work-packages/assets/worker-contract.md`

## What was needed, and why

Acceptance criterion 4 of #120 says `diff plugins/agentic-work-packages/skills/agentic-work-packages/assets/worker-contract.md .claude/worker-contract.md`
must be empty. The path is in `allowedPaths`. The harness denied the write anyway
("requires approval ... a sensitive file"), and this session has nobody to
approve a prompt, so every later write to that path is denied the same way.

Done on the branch (uncommitted while this blocker stands):

- `plugins/agentic-work-packages/skills/agentic-work-packages/assets/worker-contract.md`:
  §3 has a third habit, reading `.claude/standards.json` `rules[]` for the lane
  and resolving a `#fragment` doc to its heading section. §6 step 2 runs
  `checks[]` in order, and the absent-manifest case ends in `BLOCKER.md`. §6
  step 4 has the stamp body listing each check by name, with the
  `VERIFIED: <suite or run id> @ <sha>` first line kept.
- `plugins/agentic-work-packages/agents/cell-worker.md` step 1 reads the manifest.
- `grep -n -iE 'lint|typecheck|npm'` on the asset prints nothing.

A second point for review: #120 says the absent-manifest `BLOCKER.md` has "kind
`missing capability`". `missing capability` is a bucket. The closed Kind set is
in `plugins/fleet/src/reap.js:20` and `references/coordination.md:246-252`, and a
kind outside it is not parked. The asset therefore says bucket
`on a missing capability`, kind `human-decision`, coordinator as owner.

## Alternatives searched

- `Edit`/`Write` on `.claude/worker-contract.md`: denied as a sensitive file.
- `cp` from the asset through the shell: denied by the same policy. Any other
  shell write would route around the policy, which the contract (§1) forbids.
- Leave the installed copy stale and open `[READY]`: fails AC4, and the repo's
  own workers would run under the old contract.

## The ask

S0.3-1: how does the installed copy get updated? Options: (a) the coordinator
runs `cp plugins/agentic-work-packages/skills/agentic-work-packages/assets/worker-contract.md .claude/worker-contract.md`
on this branch and the worker re-runs the checks and opens the PR; (b) a session
with an approval surface relaunches the package; (c) split the installed copy
into a coordinator-owned follow-up package. Recommendation: (a). Decide-by: before
S0.1/S0.2/S0.4 merge. Cost-of-waiting: this repo's workers keep the old §6 step 2,
which still names the checks by guess.

S0.3-2: confirm kind `human-decision` for the absent-manifest blocker, or name
another kind from the closed set.
