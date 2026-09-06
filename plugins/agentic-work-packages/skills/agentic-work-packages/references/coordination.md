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

### The cycle contract

Every cycle — every pass over the queue, whether or not it dispatched anything
— ends with an answer to "what moved forward". There are exactly three legal
answers, and "still working" is not one of them:

1. **Movement.** Named packages plus the artifact that proves it: a PR opened,
   a PR merged, a gate passed. Names and numbers, not adjectives.
2. **Exhaustion.** A statement that nothing was dispatchable, citing the live
   counts that prove it: how many packages are open, how many are blocked and
   on what, how many are in review, how many slots the WIP cap left free. The
   counts are read at the moment of the claim, not recalled.
3. **An alarm.** Work *was* dispatchable and nothing moved. That is a fault in
   the run, and it goes to the operator rather than into the next cycle.

The point of the contract is that answer 2 costs the same effort as answer 1.
A coordinator that can say "nothing is dispatchable" without citing counts will
say it while a queued package sits ready.

### After a compaction, re-derive before acting

A coordinator's session will compact. When it does, the next action is to
re-derive wave state from the tracker and the open PRs, before dispatching,
relabelling or logging anything. A claim that exists only in the conversation
summary — "C2.3 is in review", "the gate passed" — is unverified: summaries
carry forward the shape of a fact without its evidence, and a fabricated merge
is indistinguishable from a real one until someone queries.

Query the tracker. `assets/scripts/sync-cells.sh` does this for the labels.

### The stopping condition

After **three consecutive cycles with no movement**, stop and report to the
operator. Do not start a fourth.

A loop with no stopping condition does not fail; it continues, which looks like
work and costs like work. Three is a default, not a law — what matters is that
the number exists, is stated in the epic, and is counted.

## Execution profiles

Each package declares an `execution` profile in its `SCOPE.json`: which model
tier the worker runs on, which subagent pattern it uses, and any named agent
types. The planner assigns the default from this table when the package is cut;
the coordinator resolves the final profile at dispatch and logs any change.

| Package type | Output verifiable by a tool? | Model | Pattern |
|---|---|---|---|
| Contract change (`cell:contract-change`) | partly — the shape is, the design is not | strongest available | `implement+review` — adversarial review before the PR opens |
| Gate (`V<phase>`) | yes — that is what it produces | strongest available | `gate-verify` — an independent verifier; the browser-E2E specialist for browser gates |
| Core domain-logic feature | yes, by its tests | session default | `implement+review` |
| UI feature | yes, by the browser E2E | session default | `implement+test` — a UI specialist paired with the browser-E2E verifier. The browser E2E is required regardless; the profile only makes it declarative |
| Mechanical work (migrations, renames, version bumps, doc moves) | yes — a bounded transform against a precise spec | cheapest tier | `solo` |
| Pre-planning exploration | **no** — its output is judgement | cheap fan-out, read-only explore agents; not a package — it runs before the epic is written | n/a |

**The middle column is the deciding one.** A cheaper tier is allowed only where
the result is checked by something that is not the worker: a test, a schema, a
build, a gate — or where the work is a bounded transform against a precise
spec. Where the output is judgement that nothing downstream will catch, the
tier is not a saving; it is an unmeasured bet that surfaces two phases later as
a package built on a wrong reading.

Model tiers are named as tiers, not as model names. A model name in a template
goes stale, and per-worker pinning belongs on the launch command: a `/model`
call writes a global settings key, so it cannot pin one worker.

### The context window is part of the profile

Choosing a model silently chooses a context window, and the window drives cost
more than the per-token price does. Declare it — `window` (or `autocompact`) in
the `execution` block — or accept that the profile does not say what it costs.

A cheaper model with a larger native window can cost *more* per hour of work
than the model it replaced: the window quadruples the mean context each turn
carries, and the cheaper worker takes more turns, each re-reading that context.

Which is the measurement rule: **judge any configuration change by cost per
unit of delivered work — per merged package, per passed gate — never by cost
per day.** Cost per day falls whenever the fleet gets slower, which is the
opposite of the thing being optimized.

Deliberately excluded: per-package token budgets. The WIP cap and the wave
cadence already bound spend, and a budget number inside `SCOPE.json` goes stale
where the cap does not.

## Isolation

One git worktree per package, one PR per package into the target repo's default
branch. Worktrees matter more than they look: without them, two agents on one
checkout will fight over the index and the working tree, and the failure looks
like nondeterministic test breakage rather than a coordination bug.

### Before editing: who owns this branch

**Run `git worktree list` first.** A branch already checked out elsewhere means
another worker owns it. A failed `git worktree add` *is that signal* — it is
not an obstacle to work around by checking the branch out somewhere else, and
an agent that treats it as one has just joined another worker's lane.

When a follow-up genuinely must land on another worker's branch, use a detached
per-instance worktree and push with
`--force-with-lease=<branch>:<known-head>` — the explicit form, naming the head
you actually read. Never a plain `--force`, and never a bare `--force-with-lease`
(which leases against whatever your remote-tracking ref happens to hold, and
that ref can be stale in exactly the case the lease is meant to catch).

### Before merging: which diff you are reading

**Screen with the two-dot diff, `git diff origin/<default>..HEAD`.** The
three-dot diff — what `gh pr diff` and the PR page show — is computed against
the merge base, so it *hides* the case that matters: a branch cut from a stale
base that reverts files the default branch has advanced since. The three-dot
view shows nothing wrong because, relative to the merge base, nothing is.

Decide with `git merge-tree`:

- additions only, on files the default branch has not touched → behind but
  safe;
- removals or reversions of files advanced on the default branch → a real
  revert. Rebase; do not merge.

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

### `BLOCKER.md`

A blocker is a request for a decision, and it is answered at the speed it can
be read. These fields are required; a blocker missing any of them goes back to
the worker rather than to the coordinator's queue.

```markdown
# BLOCKER: <package id> — <one line>

**Bucket:** blocked on a merge | on a missing capability | on a decision |
            because we stopped looking
**Kind:** tracked-task | human-decision | external | foreign-lease | not-before
**Reference:** <the issue, the person, the service, the branch, or the time>
**Owner:** <who can clear it>
**Un-blocks when:** <the observable condition — an event, not a feeling>

## What was needed, and why
<the file or capability, and what the package cannot do without it>

## Alternatives searched
- <alternative> — <why it fails>
- <alternative> — <why it fails>

## The ask
<id>: <question, options inline> : <recommendation> : decide-by <event> :
cost-of-waiting <what stalls>
```

**Bucket** is for the human reading the queue. **Kind** is the machine-readable
half, and the vocabulary is closed:

| Kind | Means | Reference is |
|---|---|---|
| `tracked-task` | waiting on other work that exists and is tracked | the issue or package id |
| `human-decision` | waiting on a judgement only a person can make | the person or role |
| `external` | waiting on something outside the team's control | the service, vendor or upstream |
| `foreign-lease` | the resource is held by another worker or run | the branch, worktree or lock |
| `not-before` | waiting on a time or a scheduled event | the timestamp or event |

"Blocked because we stopped looking" is a bucket with **no kind**, deliberately.
It fails review, and any tool that enumerates the backlog reads a blocker with
no structured kind as *actionable* rather than excused. A worker that has run
out of ideas has not found a blocker; it has found the end of its own search,
and the alternatives-searched section is where that shows.

**A complete package blocked on something that cannot land this wave is parked
as a merged, tracked artifact** — a skipped test carrying its un-skip condition
in the skip message, merged — never as an indefinitely held draft PR. A held
draft rots: it falls behind its base, its review goes stale, and it is invisible
to every count the cycle contract cites. A merged skip is visible to the suite,
to the counts, and to the person who un-skips it.

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
