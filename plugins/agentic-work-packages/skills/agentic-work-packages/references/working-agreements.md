# Working agreements: how a package is executed and proved

The rest of this skill bounds *what* an agent may touch. This file says what
counts as finished. Green tests are necessary and not sufficient — most damage
comes from packages that stayed inside `allowedPaths`, opened a green PR, and
shipped something broken because the tests could not fail.

Every rule here has an incident behind it.

## Test-first is the default

- **Write the failing test before the change.** It must fail against the
  pre-change tree and pass after. A test written afterwards, against fixed code,
  proves the code runs — not that the bug is gone. An agent that cannot make a
  test fail does not yet understand the bug: that is a `BLOCKER.md`, not a
  licence to proceed.
- **Every bug fix ships a regression fixture built from the real failing input** —
  the production payload, row, or identifier. Approximations are how one bug class
  gets "fixed" three times.
- **UI packages are not done without a browser-driven end-to-end test** that
  exercises the acceptance criteria. Not a unit test with a mocked DOM.
- **"Should now work" is not a status.** Report what was run and what it printed.
- **A compile error in a test is a test failure.** Never suppress or exclude it.
- **Tests must be deterministic and order-independent** — packages run in a fleet,
  in parallel, on machines that are not the author's.
- **Test symmetric actors from both sides.** Where a domain has two players, two
  directions, two tenants, a test that exercises one side passes while the other
  is inverted.

## A gate that has never run is not a gate

The most expensive failures are not missing tests. They are tests that exist, are
correct, and never execute.

- **Never gate a test behind an environment flag nothing sets.** One regression
  test sat behind such a flag for a year while the bug it covered recurred in
  production. If CI lacks the resource a test needs, give CI the resource or fail
  loudly — never skip silently.
- **Verify CI is enabled before a wave dispatches into a repo.** One repo's
  workflows had been manually disabled for three months; every merge in that
  window shipped unchecked. Two others had no workflows at all — unverifiable, not
  good.
- **Count skips.** `40 passed, 18 skipped` is reporting a problem. Coverage that
  differs between two machines means neither runs everything.
- **A red pipeline nobody is alerted about is a dead gate too.** Alerting on gate
  failure belongs in the plan, as a package.

## Evidence is stamped to a sha

A claim that a suite passed is about a specific tree. Say which one.

The stamp is one comment on the PR, and its first line is machine-readable:

```
VERIFIED: <suite or run id> @ <full head sha>

<the command that was run>
<its summary output>
```

Three rules travel with it:

- **A push after the stamp voids it.** The evidence describes a tree that is no
  longer the one under review. Re-run and re-stamp; do not argue that the
  change was small.
- **`[READY]` requires a current stamp** — one naming the PR's present head
  sha. Without it the package is not ready; it is finished-looking.
- **Credit only the enforcing tool call.** A teammate's, a subagent's or a
  script's report that "tests pass" is a pointer to go and re-query, never a
  clearance. The stamp records what *this* run observed, and only a run that
  could have failed counts.

`assets/scripts/sync-cells.sh` parses the first line, so a stamp naming a
superseded sha never promotes a package to `cell:awaiting-review` — the same
check a reviewer would do, done every cycle.

## Classify a red before retrying it

"It failed twice, try again" is not a rule; it is the absence of one. Every red
gets classified before anything is re-run, and the class decides the response.

- **A deterministic red gets zero re-runs.** The same failure shape twice, or a
  single failure that maps to a readable code path — a stable raise, a rejected
  transition, a fixed assertion — is not a flake. Re-running it buys nothing
  and costs a full suite. It is a diagnosis assignment: read the path, form the
  hypothesis, then change something.
- **An infrastructure red gets exactly one re-run.** A missing resource, a
  crashed worker, a transient 5xx. If the second run reds identically, the
  flake hypothesis is retired — permanently, for that failure — and it is
  reclassified as deterministic.
- **A passing re-run does not erase the earlier failure.** It narrows the
  question to "what differs between the runs", which is still an open
  question.

**A verifier reports the state of the code. It never authors the green.** An
agent that re-runs a suite until it passes, or relaxes an assertion until it
holds, has produced a green that means nothing, and the cost is not the wasted
runs — it is that nobody can tell afterwards which greens were witnessed and
which were manufactured.

### Four hypotheses at a product boundary

Any red at a product boundary has four possible causes, and they are not
interchangeable:

| Hypothesis | Decidable from | |
|---|---|---|
| The test is bad by construction | the artifacts alone | self-decidable |
| The harness or fixture is buggy | the artifacts alone | self-decidable |
| The product is buggy | needs an oracle | **not** self-decidable |
| The feature was never implemented | needs an oracle | **not** self-decidable |

The first two an agent can settle by reading what it already has. The last two
need an oracle outside the code — a specification, a prior human run, a
recorded behaviour — and neither is ever handed to a worker as "make this
green". A worker told to make a red green, where the red is an unimplemented
feature, will implement whatever makes the assertion pass. That is how a stub
acquires a passing test.

## Fail loudly; no silent fallbacks

**Never add fallback logic that substitutes a different answer when the intended
one cannot be produced.** Throw, log the inputs and the alternatives considered,
and stop.

A fallback converts a *detectable* failure into a *plausible-looking wrong
answer*. In the source project a fallback in move execution let a robot play
legal-but-random moves for months while every health check stayed green; removing
it surfaced the same defect within a day as a loud, diagnosable stall.

A retry loop is recovery only if the underlying operation can succeed. Around a
deterministic failure it is an infinite loop that looks like activity.

## Boundaries where things disappear silently

Any package that adds a field, a type, or a dependency crosses at least one of
these, and its acceptance criteria must name the round-trip test explicitly.
"Tests pass" cannot catch a boundary that has no test.

- **Persistence.** A new field on a stored object needs a save → read → update
  round-trip test *before merge*. A field added to a type whose storage maps
  explicit columns is dropped on every write, with no error. If the storage layer
  maps rows to objects in more than one place, prove every mapper.
- **Serialization.** Cross-process boundaries mutate values in ways types do not
  describe (`undefined` → `null`, a set arriving as an array). Assert on what
  comes off the wire.
- **Declared dependency ranges.** Code needing a new symbol from a sibling package
  must have the *declared range* bumped, not just the lockfile refreshed. A range
  that still satisfies the old locked version means the package manager never
  moves, CI installs from the lock, and the build dies in the type checker while
  developer machines pass on a hand-refreshed tree. A lock-only refresh cannot fix
  this.

## Deploy verification means exercising the feature

Artifacts are not evidence. Image digests, health endpoints, bundle hashes and a
green pipeline together prove only that *something* deployed.

- A user-facing flow is unverified until it has been run once, end to end, after
  the deploy.
- Where no staging environment exists, say so and ask. The honest options are one
  sanctioned production exercise or an explicitly accepted risk.
- **Never propose changing production configuration to make a local test
  possible.**
- **Verify the account or target before any infrastructure command.** Deploying to
  the wrong account is not recoverable by a revert.

## Multi-repo sequencing

Where packages target several independent repos, sequencing is part of the plan.

- **Merge in dependency order**; a dependency merged but not *released* is still
  blocking.
- **A commit is not a delivery** when repos consume each other as published
  packages. The release step is its own package.
- **Promote to the release branch before publishing.** Publishing from the working
  branch leaves the registry pointing at a commit that is not on the release
  branch. Promotion must be a fast-forward; a merge commit puts the branches one
  apart and trips drift checks.
- **The trigger repo is pushed last** where a deploy workflow re-clones each
  dependency at its current release branch.
- **Never chase history across a repo boundary**, and confirm which repo the shell
  is in before running anything.

## Destructive commands

- **Never pattern-kill a process fleet by substring.** `pkill -f '<script> run 2'`
  matches `run 200`; that killed a twenty-worker run fifty minutes in. Kill by PID
  captured at launch, or anchor the pattern. **Always `pgrep -af` and read the
  matched lines first** — a match count larger than expected means the pattern is
  too broad, not that there is more to clean up.
- **`git stash` is banned in worker worktrees** (see `references/coordination.md`).
- **Look at the target before deleting or overwriting it.**

## Verify external claims at the source

The "cite file:line evidence, not speculation" rule extends past the codebase.
Before any plan resting on an external fact — who owns a domain, a company, a
package name; what a registry or spec actually says — run the primary-source
lookup **first**. A fact labelled "unverified" in a planning document is not
licensed for use because it is labelled. If the check is cheap, the check is the
next action, never the inference.

## Reporting

- **Bullets by default.** A yes/no question gets a yes/no answer, first.
- **Lead with the ask** when the operator must act.
- **Depth of investigation does not license length of report.**
- **Be unambiguous about bug state** — discovered, under investigation, fixed,
  verified fixed. "Fixed" without a run behind it is the most expensive word an
  agent can use.

## Adding these to a plan

- Package acceptance criteria name the **failing test first**; UI packages name the
  **browser E2E**.
- A red is **classified before it is retried**, and a blocked package files a
  `BLOCKER.md` with a structured kind — see `coordination.md` §`BLOCKER.md`.
- Evidence is **stamped to the head sha**, and `[READY]` waits for a current
  stamp.
- Any package adding a field, type or dependency names its **boundary round-trip
  test**.
- The target repo has **CI enabled, running, and free of silently skipped suites** —
  verified before the wave, not after.
- Release and deploy **sequencing is a package**, in dependency order.
- Deploy gates require the **feature to be exercised**, not artifacts inspected.
