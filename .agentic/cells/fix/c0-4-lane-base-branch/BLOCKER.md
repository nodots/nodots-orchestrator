# BLOCKER: C0.4 — the installed hook copies under .claude/hooks/ cannot be written from the worker session

**Bucket:** blocked on a missing capability
**Kind:** human-decision
**Reference:** #216; `.claude/hooks/enforce-scope.js`, `.claude/hooks/require-handoff.js`
**Owner:** the coordinator (Ken Riley)
**Un-blocks when:** both `.claude/hooks/` copies are byte-identical to `plugins/agentic-work-packages/hooks/` on `fix/c0-4-lane-base-branch`, and `bash scripts/test.sh` ends `ALL PASS`

## What was needed, and why

C0.4 changes `enforce-scope.js` and `require-handoff.js` "in all three copies"
(#216, Scope of work), and `scripts/test.sh:51-58` fails any `.claude/hooks/`
copy that differs from `plugins/agentic-work-packages/hooks/`. Both
`.claude/hooks/` paths are in `allowedPaths`, but this session's permission
settings treat `.claude/hooks/*` as a sensitive file. Every `Edit` was denied
("requires approval … no approval surface"), and so was `cp` into
`.claude/hooks/`. The session is non-interactive, so nobody can approve.

Everything else is done and committed on the branch: the hooks in
`plugins/agentic-work-packages/hooks/` and their `assets/hooks/` copies
(byte-identical), `scope.js`, `launch.js`, the two references and the four
tests. All four package tests pass (81, 58, 30 and 71 checks, 0 failed).
`bash scripts/test.sh` fails only on the copy check:

```
FAIL  .claude/hooks/enforce-scope.js differs from plugins/agentic-work-packages/hooks/enforce-scope.js
FAIL  .claude/hooks/require-handoff.js differs from plugins/agentic-work-packages/hooks/require-handoff.js
FAIL  scripts/tests/v0-gate.test.sh  --- 11 checks, 2 failed
        FAIL  clean copy: test.sh exits 0
        FAIL  clean copy: test.sh prints ALL PASS
FAILED
```

The `v0-gate` failure is the same cause: it runs `test.sh` on a clean copy
of the tree, and its nested output names the same two copy checks. No other
test failed.

## Alternatives searched
- `Edit` on `.claude/hooks/*.js`: denied as a sensitive file.
- `cp plugins/agentic-work-packages/hooks/*.js .claude/hooks/`: denied, needs approval.
- Writing the blobs through git plumbing (`hash-object` / `update-index`) or any
  other indirect write: rejected. It routes around a permission control, which
  the worker contract §1 names as a worse failure than the one it stopped.
- Leaving the copies stale and opening `[READY]`: rejected. An acceptance
  criterion ("the three hook copies are byte-identical") and the `test` check
  would both be red.

## The ask
C0.4-copies: sync the two installed hooks — (a) the coordinator runs
`cp plugins/agentic-work-packages/hooks/{enforce-scope,require-handoff}.js .claude/hooks/`
on this branch, commits, runs `bash scripts/test.sh`, and stamps and opens the
`[READY]: C0.4` PR; (b) relaunch the worker with approval for `.claude/hooks/**`
edits : recommend (a), one command and the rest is verified : decide-by the
next fleet cycle : cost-of-waiting C0.4 and #215 stay open, and every worker cut
from an integration branch is still blocked at the stop.
