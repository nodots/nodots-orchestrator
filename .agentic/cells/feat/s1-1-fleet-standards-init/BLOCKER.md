# BLOCKER: S1.1 — the branch needs `origin/development` merged, and this session may not run `git merge`

**Bucket:** on a missing capability
**Kind:** human-decision
**Reference:** #124 ("On relaunch" note), #139 (`2232bff` on `origin/development`), `.claude/settings.json:3-18`
**Owner:** coordinator
**Un-blocks when:** `origin/development` (at or after `2232bff`) is merged into `feat/s1-1-fleet-standards-init`, or the worker session is allowed `git fetch` and `git merge`

## What was needed, and why

The package's relaunch note says: merge `origin/development` first so the gate
carries the S1.1a exemption, then rewrite the README and re-run the checks.

- README rewrite: done, commit `493ebac` (`plugins/fleet/README.md:177-180` no
  longer contains the command literals).
- Merge: refused. `git fetch origin` and `git merge --no-edit origin/development`
  were both denied by the permission layer (headless session, no approval
  surface). `.claude/settings.json:3-18` allows `git status/diff/log/add/commit/push`
  but not `git fetch` or `git merge`.

Without the merge, the SV0 gate on this branch has no exemption. Observed run of
`bash plugins/agentic-work-packages/skills/agentic-work-packages/assets/tests/sv0-standards-gate.test.sh`:

```
  FAIL  text: git grep ran and matched nothing (exit 1)
  FAIL  text: no tool or command name in plugins or docs outside tests
        expected empty, got [plugins/fleet/src/standards.js:18:  ['lint', 'npm run lint'],
plugins/fleet/src/standards.js:19:  ['typecheck', 'npm run typecheck'],
plugins/fleet/src/standards.js:20:  ['build', 'npm run build'],
plugins/fleet/src/standards.js:21:  ['test', 'npm test'],]
  --- 69 checks, 2 failed
```

`bash scripts/test.sh` ends `FAILED` for the same reason. The only remaining hits
are in `plugins/fleet/src/standards.js`, the file #139 exempts. The red is
deterministic and its fix is outside what this session can run.

## Alternatives searched
- Run the merge through another process (e.g. `node -e` spawning git) — routes around the permission layer; the contract (§1) forbids that kind of bypass.
- Edit `sv0-standards-gate.test.sh` on this branch to add the exemption — the path is forbidden (`plugins/agentic-work-packages/**`), and it would duplicate #139 and conflict with it.
- Rewrite `standards.js` to avoid the literals (e.g. build `'npm ' + 'run'`) — defeats the invariant's intent; decision S1.1-text exempts the file instead.
- Open the PR anyway with a red stamp — `[READY]` requires `bash scripts/test.sh` to end `ALL PASS`.

## The ask
S1.1-merge: who merges `origin/development` into this branch? Options: (a) the
coordinator runs `git merge origin/development` on the branch and pushes, then
relaunches; (b) add `Bash(git fetch:*)` and `Bash(git merge:*)` to the worker
allowlist : recommend (a), it is a one-time step and keeps the worker allowlist
unchanged : decide-by next fleet cycle : cost-of-waiting S1.1 PR, and S1.2 work
that assumes `fleet standards init` exists
