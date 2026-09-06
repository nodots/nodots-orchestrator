# Writing a work package

A package is the unit an autonomous agent executes. It succeeds or fails on one
property: **can a competent agent that has never seen this codebase finish it
without asking a question?**

## Sizing

One bounded change, finishable in one sitting, provable with tests. Split it if:

- acceptance criteria exceed about six checkboxes;
- `allowedPaths` spans two subsystems;
- it needs changes in two repositories — that is always two packages, merged in
  dependency order;
- it needs both a schema migration and feature code — separate the migration.

## Sections

Five, in order. No more; length is not thoroughness.

### Header line

`**Part of** <epic> · **Phase 0 · <name>** · **Repo:** <repo>`

The repo is stated even in a monorepo — say the package or workspace instead.

### Goal

One paragraph: which gap this closes, and the failure it prevents. An agent that
understands the failure makes better judgement calls inside its lane.

### Scope of work

Bullets naming files, functions and line ranges. This is the section that
converts exploration into instructions. `src/routes/games.ts:192-300` beats "the
game routes".

Include the constraints that are not visible from the code — the things an agent
would break precisely because they look irrelevant. For example: "automated
turns are driven by the server-side queue, not by REST, and must be unaffected",
or "map token identity to the database user id the same way the existing
ownership check does (`x.ts:481-507`)".

### SCOPE.json

A fenced `json` block, verbatim, ready to copy to disk. Full field reference in
`scope-contract.md`. Two rules people get wrong:

- **`allowedPaths` must include the package's test paths.** An agent that cannot
  write tests cannot satisfy the definition of done.
- **`forbiddenPaths` must exclude the serialising paths** — frozen contracts and
  interfaces, migrations, dependency manifests, CI config, and the other
  subsystem's directory. These are where parallel agents collide.

### Acceptance criteria

Checkboxes, each observable by the agent without asking anyone. Prefer
statements about behaviour under a named test over statements about code shape.

Add a **regression criterion** whenever the package touches a shared path:
"existing `<suite>` passes unchanged". This is what stops an agent solving its
own problem at someone else's expense.

End with the standing closers:

```
- [ ] Tests pass · build/typecheck passes · lint passes
- [ ] `[READY]:` PR opened, linked to this package
```

### Dependencies

`**Depends on:** #N, #N · **Parallelizable:** yes — alongside #N, #N.`

State parallelism explicitly; the coordinator schedules from this line. `none`
is a valid and useful answer — it marks the package as first-wave.

## Template

````markdown
## X0.1 — <title>

**Part of** <epic link> · **Phase 0 · <name>** · **Repo:** `<repo>`

### Goal
<one paragraph: the gap this closes and the failure it prevents>

### Scope of work
- <file:line-level instruction>
- <file:line-level instruction>
- <non-obvious constraint that must not be broken>

### SCOPE.json
```json
{
  "feature": "<kebab-feature>",
  "project": "<project>",
  "branch": "feat/<kebab-feature>",
  "allowedPaths": ["<src paths>", "<test paths>"],
  "forbiddenPaths": ["<frozen contract>", "<migrations>", "<manifests>", "<ci>"],
  "dependsOn": ["feat/<upstream-branch>"],
  "estimatedScope": "<one line, for the coordinator's queue view>"
}
```

### Acceptance criteria
- [ ] <observable behaviour, ideally under a named test>
- [ ] <negative case: what must be rejected or must not happen>
- [ ] Existing <suite> passes unchanged
- [ ] Tests pass · build/typecheck passes · lint passes
- [ ] `[READY]:` PR opened, linked to this package

### Dependencies
- **Depends on:** none · **Parallelizable:** yes — alongside #N, #N.
````
