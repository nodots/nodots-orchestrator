# Dispatch and coordination

## Waves and the WIP cap

Packages dispatch in **waves**. A wave is every package whose `dependsOn`
branches have all merged, up to the WIP cap.

A cap of **four concurrent agents** is a sound default. It is not about compute;
it is about how many parallel changes one reviewer can hold in their head when
the merge order matters. Raise it only when packages are genuinely disjoint and
review is not the bottleneck.

Log each wave in the epic's progress log: which packages went out, and which
dependency clearing let them go.

## The coordinator

One agent or human coordinates. **The coordinator does not write feature code.**
It:

- promotes packages from blocked to queued as dependencies merge;
- dispatches waves within the WIP cap;
- sequences merges when packages touch adjacent code;
- resolves `BLOCKER.md` escalations, usually by filing a new package;
- resolves each package's execution profile at dispatch (§Execution profiles);
- maintains the epic's checkbox list and progress log.

A coordinator that starts implementing loses track of the fleet, and the logs
stop being written. That is how a run silently degrades into one agent doing
everything.

**Scope-down at dispatch is allowed, and logged.** The coordinator may shrink a
package as it goes out — "the migration file only, no deploy" — and records the
shrink on the wave's progress-log entry. What it may not do is widen one.

**Escalation on failure is a re-dispatch, not an edit.** A package that files
`BLOCKER.md` or fails review twice is re-dispatched one model tier up, or with
a reviewer added to its pattern. The escalation goes in the progress log; the
package's declared `SCOPE.json.execution` default is left alone, so the record
shows what was planned and what it actually took. An escalation that is not
logged is the same as no escalation: the next planner repeats the
under-provisioning.

## Execution profiles

Each package declares an `execution` profile in its `SCOPE.json`: which model
tier the worker runs on, which subagent pattern it uses, and any named agent
types. The planner assigns the default from this table when the package is cut;
the coordinator resolves the final profile at dispatch and logs any change.

| Package type | Model | Pattern |
|---|---|---|
| Contract change (`cell:contract-change`) | strongest available | `implement+review` — adversarial review before the PR opens |
| Gate (`V<phase>`) | strongest available | `gate-verify` — an independent verifier; the browser-E2E specialist for browser gates |
| Core domain-logic feature | session default | `implement+review` |
| UI feature | session default | `implement+test` — a UI specialist paired with the browser-E2E verifier. The browser E2E is required regardless; the profile only makes it declarative |
| Mechanical work (migrations, renames, version bumps, doc moves) | cheapest tier | `solo` |
| Pre-planning exploration | cheap fan-out | read-only explore agents; not a package — it runs before the epic is written |

Model tiers are named as tiers, not as model names. A model name in a template
goes stale, and per-worker pinning belongs on the launch command: a `/model`
call writes a global settings key, so it cannot pin one worker.

Deliberately excluded: per-package token budgets. The WIP cap and the wave
cadence already bound spend, and a budget number inside `SCOPE.json` goes stale
where the cap does not.

## Isolation

One git worktree per package, one PR per package into the target repo's default
branch. Worktrees matter more than they look: without them, two agents on one
checkout will fight over the index and the working tree, and the failure looks
like nondeterministic test breakage rather than a coordination bug.

**`git stash` is banned in worker worktrees.** A worktree isolates files; it does
not isolate the stash. Linked worktrees of one repo share a single stack at
`<common-dir>/refs/stash` — common state, not per-worktree state like `HEAD` or
the index — so `stash@{0}` is whatever *any* worktree pushed most recently, and a
positional `git stash pop` takes another worker's changes into the wrong tree. It
fails silently in both directions: the owner's worktree goes clean, which reads as
"my changes vanished" rather than as a collision, and the popper's next build or
suite run measures foreign changes.

The trigger is the before/after measurement — stash, take a baseline, pop, measure
again — so brief workers off it. Use a patch file, which cannot reach out of one
worktree: `git diff > <path outside the tree>`, move untracked files aside,
`git checkout -- .`, measure, then `git apply` the patch and restore the files. If
a stash exists anyway, recover it by reference and never by position:
`git stash list --format='%gd %gs'`, find the entry whose message names this
package's branch, `git stash pop <that ref>`.

## Coordination files

| File | Written by | Meaning |
|---|---|---|
| `SCOPE.json` | coordinator | the lane |
| `BLOCKER.md` | worker | stopped; needs a decision. Names what was needed and why |
| `HANDOFF.md` | worker | context for whoever picks this up next |

All three are always writable regardless of scope.

## Two levels of fan-out

Across packages, the coordinator drives up to the WIP cap. Within a package, a
worker may spawn its own subagents — implementer and tester, say — under the
same `SCOPE.json`. The lane is inherited; the sub-fan-out does not widen it.

## The logs

Two append-only logs at the bottom of the epic.

**Decisions log** — every choice that constrains later packages, dated, with its
reason and what it leaves reversible. Example shape: "engine implemented in
TypeScript for stack fit; the HTTP boundary makes this reversible — the service
can be reimplemented in any language without touching the protocol or any other
package." Without it, a later agent re-litigates the choice.

**Progress log** — waves dispatched, gates passed, packages scoped down mid-run,
and cross-package requirements discovered during execution. That last category
is the one that justifies the log: requirements that exist nowhere in the code
and nowhere in the original plan. "Package B left validation injectable, so the
wiring packages **must** configure the resolver — an unwired resolver ships
unvalidated input" is a fact no agent can derive from reading its own lane.

Append only. Never rewrite either log; the value is the trail.

## When a package uncovers unplanned work

It will. A package reaches its boundary and finds the thing it depends on is a
stub, or that two subsystems disagree about a convention.

The response is fixed:

1. the worker stops at the boundary and writes `BLOCKER.md`;
2. the coordinator files a **new package**, numbered into the phase where it
   belongs — `C2.0k`, not appended at the end;
3. the epic's checkbox list and the affected `dependsOn` entries are updated;
4. the progress log records the gap and the new package.

Follow-ups too small for their own package are **tracked on a named package** —
say which one carries it, in the progress log. Anything not attached to an ID is
lost.

## Anti-patterns

- **A package without file paths.** The exploration was not done; the agent will
  do it badly and confidently.
- **`allowedPaths` that exclude tests.** Guarantees a failed definition of done.
- **Two repos in one package.** Two PRs, two reviews, two release cadences.
- **A gate that can edit the implementation.** It will fix rather than fail.
- **Renumbering.** Breaks `dependsOn`, branch names, and every prior reference.
- **Marking human-judgement work agent-ready.** Browser verification against a
  deployed environment, product decisions, production credentials.
- **Silent scope widening.** See `scope-contract.md`.
- **An epic with no Out of scope section.** The fence is the point.
- **A coordinator that writes feature code.** The logs stop; the fleet drifts.
- **Sizing by estimate rather than by boundary.** "Three days of work" is not a
  package. "These four files, provable by this test" is.
