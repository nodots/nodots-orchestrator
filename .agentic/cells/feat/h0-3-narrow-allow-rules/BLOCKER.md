# BLOCKER: H0.3 — the worker cannot write `.claude/settings.json`

**Bucket:** on a missing capability
**Kind:** human-decision
**Reference:** #186; branch `feat/h0-3-narrow-allow-rules`
**Owner:** the coordinator (Ken Riley)
**Un-blocks when:** a commit on `feat/h0-3-narrow-allow-rules` replaces `Bash(node:*)` in `.claude/settings.json`, or a session that can approve that write is dispatched

## What was needed, and why

The first scope item and the first two acceptance criteria of #186 need
`.claude/settings.json` to drop `Bash(node:*)`. The path is in `allowedPaths`.
The scope hook allowed the `Edit`, but Claude Code's own permission layer
treats `.claude/settings.json` as protected and asks for approval. This
unattended session has no one to approve it, so the write was denied
automatically. Writing it with a shell redirect would route around a permission
denial; contract §1 forbids that.

The intended change, which keeps the `hooks` key as it is:

```diff
       "Bash(bash plugins/*)",
-      "Bash(node:*)"
+      "Bash(node plugins/*)",
+      "Bash(node scripts/*)",
+      "Bash(node evals/*)"
```

`Bash(node:*)` gave the worker `node` for the hooks' own tests and for the
eval tests (`node evals/...`) and the fleet CLI (`node plugins/fleet/bin/fleet.js`).
The only `checks[]` entry is `bash scripts/test.sh`, which `Bash(bash scripts/*)`
already covers. The harness runs the hooks themselves (`node "$CLAUDE_PROJECT_DIR/.claude/hooks/..."`);
Bash permission rules do not apply to them.

## Alternatives searched

- `Edit` on `.claude/settings.json`: denied, "requires approval, and this session has no approval surface".
- A shell write (`sed -i`, `node -e`, redirect): a permission bypass, forbidden by contract §1 and REVIEW.md's security pass.
- Ship the doctor check and docs alone as `[READY]`: acceptance criteria 1 and 2 would be unmet, so it is not ready.

## The ask

H0.3-settings: who applies the settings diff above? Options: (a) the coordinator
commits it on this branch, then a worker re-stamps and opens the `[READY]` PR;
(b) re-dispatch with a permission mode that allows the write. :
recommend (a), because it is one reviewed line and keeps workers unable to edit
their own permissions : decide-by the next coordinator cycle : cost-of-waiting
H0.3 stays open, so the downstream settings PR for the other target is held.
