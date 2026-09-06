# The SCOPE.json contract

`SCOPE.json` is what makes unattended parallel execution safe. It states, as
paths, exactly what one agent may touch — and a PreToolUse hook enforces it, so
the boundary holds whether or not the agent is paying attention.

Without mechanical enforcement this is a comment, and lanes will be crossed.

## Fields

```json
{
  "feature": "route-authorization",
  "project": "my-project",
  "branch": "feat/route-authorization",
  "allowedPaths": ["src/routes/orders.ts", "src/middleware/**", "src/**/*.test.ts"],
  "forbiddenPaths": ["src/websocket/**", "migrations/**", "package.json", ".github/**"],
  "dependsOn": ["feat/upstream-thing"],
  "estimatedScope": "auth middleware on mutating routes + caller-identity enforcement"
}
```

| Field | Meaning |
|---|---|
| `feature` | Kebab identifier; matches the branch suffix |
| `project` | Project or repo name, for logs |
| `branch` | The one branch this package uses. One package, one branch |
| `allowedPaths` | Everything the agent may edit, **including its test paths** |
| `forbiddenPaths` | Denied even if `allowedPaths` would match. Evaluated last |
| `dependsOn` | **Branch names**, not issue IDs — this is what tooling reads |
| `estimatedScope` | One line, for the coordinator's queue view |

The asymmetry between `dependsOn` (branches) and the issue's `Depends on` line
(issue IDs) is intentional: one is for machines, one is for people. Both must
express the same dependency.

### Choosing allowedPaths

Narrow enough to prevent collision, wide enough to finish the job. The common
failure is forgetting tests, which makes the definition of done unreachable.

### Choosing forbiddenPaths

Always deny the **serialising paths** — anything whose concurrent edit breaks
everyone:

- frozen contracts, shared interfaces, protocol or schema packages;
- database migrations, except in the one package that owns a migration;
- dependency manifests and lockfiles;
- CI configuration;
- the other subsystem's directory, when two phases run in parallel.

A change to any of these gets its own package, dispatched alone.

## Enforcement

`assets/hooks/enforce-scope.js` is a PreToolUse hook that blocks `Edit` and
`Write` outside `allowedPaths` or matching `forbiddenPaths`. Node builtins only,
no dependencies.

Install per repo:

```bash
mkdir -p .claude/hooks
cp <skill>/assets/hooks/enforce-scope.js .claude/hooks/
# merge assets/settings-snippet.json into .claude/settings.json
```

Resolution order for `SCOPE.json`:

1. `.agentic/cells/<branch>/SCOPE.json` — branch-scoped, preferred
2. `.auto-shop/cells/<branch>/SCOPE.json` — legacy branch-scoped
3. `<repoRoot>/SCOPE.json` — fallback

Behaviour worth knowing before you rely on it:

- **No `SCOPE.json` present means no restriction.** The default branch and
  ad-hoc work are unaffected; enforcement applies only while a package is live.
- `SCOPE.json`, `HANDOFF.md` and `BLOCKER.md` are always writable — an agent
  must always be able to escalate.
- Branch-scoped resolution needs a resolvable branch. In a repo with no commits
  yet, `git rev-parse --abbrev-ref HEAD` fails and the hook falls back to the
  root path.
- It **fails open**: any hook error exits zero rather than blocking work. It is
  a guardrail, not a security control.
- It governs `Edit` and `Write` only. Shell commands are not intercepted, so an
  agent determined to route around it can. That is a coordination signal, not a
  threat model.

## Worker protocol

An agent that hits a scope violation:

1. **stops**;
2. writes `BLOCKER.md` — what it needed, why, and what it proposes;
3. does not widen `SCOPE.json`, and does not work around the block.

A scope violation means the package was mis-specified. The fix is a coordinator
decision, and usually a new package. Widening the lane silently is the single
most damaging failure in this model: it is undetectable until two agents produce
conflicting work on the same file.
