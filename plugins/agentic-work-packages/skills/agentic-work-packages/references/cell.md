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

### Execution profile

`SCOPE.json.execution` declares how the package is run: model tier, subagent
pattern, context window, and any named agents. The planner assigns it at cut
time from the table in `coordination.md` §Execution profiles; the coordinator
may resolve it differently at dispatch and logs the change on the wave entry.
Field reference in `scope-contract.md`.

Two rules travel with it:

- **A cheaper tier needs a tool that checks the output** — a test, a schema, a
  build, a gate — or a bounded transform against a precise spec. Ask the
  question the profile table asks: is this package's output verifiable by a
  tool? If the answer is no, the cheap tier is an unmeasured bet. Name the
  check in `execution.verifiedBy`; the fleet runtime refuses a `cheapest`
  package without it. It confirms the field is present, not that the check is
  adequate, and it does not measure blast radius.
- **State the `window`.** Choosing a model chooses a context window, and the
  window drives cost more than the per-token price. A profile that omits it
  does not say what the package costs.

### Verifier restatement (optional, and worth it)

For the `implement+test` and `gate-verify` patterns, add a step before any code
is written: **the verifier restates the acceptance criteria as the exact
commands and tests it will run**, and the worker builds to that restatement.

The restatement comes from the verifier, not the implementer, because an agent
grading its own output grades what it meant. Where the restatement and the
criteria disagree, the package is defective — file the defect and fix the
package *before* code exists, which is the cheapest moment it will ever be.
Leave a placeholder in the package for the restatement so it is visible in
review.

### Acceptance criteria

Checkboxes, each observable by the agent without asking anyone. Prefer
statements about behaviour under a named test over statements about code shape.

Add a **regression criterion** whenever the package touches a shared path:
"existing `<suite>` passes unchanged". This is what stops an agent solving its
own problem at someone else's expense.

End with the standing closers:

```
- [ ] Every check in `.claude/standards.json` passes
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
  "baseBranch": "<optional: the integration branch it is cut from and merges into>",
  "allowedPaths": ["<src paths>", "<test paths>"],
  "forbiddenPaths": ["<frozen contract>", "<migrations>", "<manifests>", "<ci>"],
  "dependsOn": ["feat/<upstream-branch>"],
  "estimatedScope": "<one line, for the coordinator's queue view>",
  "execution": {
    "model": "<cheapest | session default | strongest available>",
    "pattern": "<solo | implement+review | implement+test | gate-verify>",
    "window": "<context window, or the autocompact setting>",
    "agents": []
  }
}
```

### Verifier restatement
_(filled in by the verifier before implementation starts, for `implement+test`
and `gate-verify` packages; delete for `solo`)_
- Commands: `<exact command>`
- Tests: `<exact test names>`

### Acceptance criteria
- [ ] <observable behaviour, ideally under a named test>
- [ ] <negative case: what must be rejected or must not happen>
- [ ] Existing <suite> passes unchanged
- [ ] Every check in `.claude/standards.json` passes
- [ ] `[READY]:` PR opened, linked to this package

### Dependencies
- **Depends on:** none · **Parallelizable:** yes — alongside #N, #N.
````
