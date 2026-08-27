# Writing an epic

An epic is an **execution plan for agents**, not a wish list and not a
requirements document. Its job is to make every child package dispatchable
without further human explanation, and to survive the agents that read it — none
of which will remember the previous wave.

## Prerequisite

Exploration is done and written down. The context section is where a human's
understanding of the codebase is converted into something agents can act on. If
you cannot yet name the gaps at file level, you are not ready to file the epic.

## Draft epics

An epic that lists *proposed* children as bare checkboxes, with open questions
still open, is legitimate and useful. Mark it as a draft, do not mark it
agent-ready, and do not dispatch against it. It becomes a real epic when the
checkboxes become filed packages with `SCOPE.json` blocks.

## Sections

1. **Title** — `Epic: <program name>`.
2. **Lead blockquote** — one line: this is the agentic execution plan for X, and
   the design rationale lives at Y.
3. **Context** — two parts, both required:
   - what **already works** and therefore must not be touched, with file
     references. This prevents agents rebuilding what exists.
   - a numbered list of the **gaps this epic closes**, each with the file paths
     where the gap lives. These become packages roughly one-to-one.
4. **Execution model** — the invariants, the WIP cap, what is frozen, the
   coordinator/worker protocol, the status lifecycle. Mostly boilerplate; copy
   the template below and change what differs.
5. **Definition of done (every package)** — the standing checks, stated once
   here so packages can be terse.
6. **Success criteria (epic)** — observable outcomes, not tasks. "Two
   authenticated users on separate devices complete a full session, every
   mutation server-verified" is a criterion. "Add auth middleware" is not.
7. **Out of scope** — with a link to whatever inherits each excluded item. This
   is the fence that stops an agent expanding; an epic without one will grow.
8. **Workstreams & packages** — phases, each a checkbox list of packages ending
   in its gate. This list is the progress display; keep it ticked.
9. **References** — pattern epics, the package template, related work, key paths.
10. **Decisions log** — dated, append-only. Every choice that constrains later
    packages, with its reason. Without this, a later agent re-litigates the
    choice and produces something inconsistent.
11. **Progress log (live)** — dated, append-only, maintained by the coordinator:
    waves dispatched, gates passed, packages scoped down mid-run, integration
    requirements discovered. This is where cross-package requirements live that
    exist nowhere in the code — for example, "package B left validation
    injectable, so the wiring packages **must** configure the resolver; an
    unwired resolver ships unvalidated input."

## Template

````markdown
# Epic: <program name>

> This epic is the **agentic execution plan** for <thing>. Design rationale:
> <link>. Model: `agentic-work-packages` skill.

## Context

<what already works, with file references — do not rebuild this>

The gaps this epic closes:

1. **<gap>** — <where it lives, file:line>
2. **<gap>** — <where it lives, file:line>

## Execution model

- **Package = one subissue** = one bounded change, one branch, one `SCOPE.json`,
  one worker agent, one `[READY]` PR.
- **Parallel by default, sequential by declaration.** Independent packages run
  concurrently up to a **WIP cap of <N>**. Dependencies are declared in three
  mirrored places: the `Depends on:` line, `SCOPE.json.dependsOn`, and each
  phase's blocking gate.
- **Repos:** <list>; default branch <name>. Workers run in git worktrees, one
  `[READY]` PR per package.
- **Frozen boundaries.** Every package's `forbiddenPaths` excludes <contract>,
  <migrations> (except <the one package that owns them>), dependency manifests
  and CI config.
- **Coordinator <-> worker via files.** Workers escalate with `BLOCKER.md`, hand
  off with `HANDOFF.md`. The coordinator manages boundaries, unblocks, sequences
  merges — it does not write feature code.
- **Status lifecycle:** queued -> active -> awaiting-review -> merged. A package
  is queued only once every branch in its `dependsOn` has merged.

## Definition of done (every package)

- [ ] Acceptance criteria met
- [ ] Tests pass · build/typecheck passes · lint passes
- [ ] `SCOPE.json` respected (no edits outside `allowedPaths`)
- [ ] `[READY]:` PR opened, linked to the package issue

## Success criteria (epic)

- [ ] <observable outcome>
- [ ] <observable outcome>
- [ ] <existing behaviour X remains unaffected>

## Out of scope

- <item> — inherited by <link>
- <item> — not planned

## Workstreams & packages

**Phase 0 · <name> (`<repo>`)**
- [ ] #N · X0.1 <title>
- [ ] #N · X0.2 <title>
- [ ] #N · **V0 gate** — <what it proves>

**Phase 1 · <name> (parallel with Phase 0)**
- [ ] #N · X1.1 <title>
- [ ] #N · **V1 gate** — <what it proves> (held for a human: <why>)

## References

- Pattern epic: <link> · package template: <link>

---

## Decisions log

- **<YYYY-MM-DD> — <subject>:** <decision, reason, and what it makes reversible>

---

## Progress log (live)

_(empty — updated by the coordinator as waves dispatch and merge)_
````
