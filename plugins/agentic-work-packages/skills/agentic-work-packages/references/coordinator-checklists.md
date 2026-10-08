# Coordinator checklists

Use this when running the coordinator role as a recurring routine: opening a
wave, reviewing blocked work and finished PRs, merging in order, and preparing
the next wave. `coordination.md` defines the role, the WIP cap, derived labels
and the cycle contract, and `multi-account.md` adds assignment across accounts.
This file is the checklist form of that work, plus the cadence and the
troubleshooting cases.

The coordinator manages boundaries between packages: unblocking workers,
reviewing finished work and sequencing merges. It does not direct
implementation.

## Cadence

A human coordinator who batches review can run the work as two sessions a day,
each 20 to 30 minutes:

- **Opening session:** unblock, review, start new packages.
- **Closing session:** merge in order, prepare the next wave.

Each session is a pass over the queue, so it ends with one of the three answers
in `coordination.md` §The cycle contract, and its entry goes in the epic's
progress log.

If a session routinely runs past 40 minutes, treat that as a signal about the
plan:

- Packages too large: split them (`cell.md` §Sizing).
- Blockers too frequent: improve how `SCOPE.json` is designed
  (`scope-design.md`).
- Merges slow: improve CI or the merge tooling.

## Opening a wave

```
[ ] Run assets/scripts/sync-cells.sh, then read the queue
[ ] Review cell:blocked packages
[ ] Review PRs marked [READY]
[ ] Count cell:active against the WIP cap
[ ] Dispatch the next wave if there is capacity
[ ] Log the wave and the session in the progress log
```

### 1. Review blocked packages

For each package carrying `cell:blocked`, read the issue and the `BLOCKER.md`
on its branch, then decide by the blocker's `Kind` (`coordination.md`
§`BLOCKER.md`):

- **`tracked-task`:** check whether the referenced work has merged. If it has,
  tell the worker to resume. If it has not, record when it is expected.
- **`human-decision`:** decide, or route to the person named in `Owner`, and
  record the decision on the issue and in the decisions log. Then the worker
  resumes.
- **`external`:** note what is awaited and from whom; the package stays blocked.
- **`foreign-lease`:** find the other holder before doing anything else; see
  `coordination.md` §Isolation.
- **A blocker that asks for a wider lane or a missing contract:** the answer is
  a new package, usually a contract change, and the dependent package gets a
  `dependsOn` entry. See `coordination.md` §When a package uncovers unplanned
  work and `scope-contract.md` §Worker protocol.
- **Cannot resolve it:** escalate (below).

Do not set `cell:*` labels by hand to record the outcome. The next
`sync-cells.sh` run derives them from the branch, the PR and `BLOCKER.md`.

### 2. Review finished PRs

For each PR marked `[READY]` (`cell:awaiting-review` once it carries a current
stamp):

- [ ] A `VERIFIED` stamp names the PR's present head sha
      (`working-agreements.md` §Evidence is stamped to a sha).
- [ ] CI is green.
- [ ] `HANDOFF.md` has no open concerns.
- [ ] The diff stays inside `allowedPaths`; read it with the two-dot diff
      (`coordination.md` §Before merging).

If any item fails, comment on the PR and leave it unmerged. If all pass,
approve it and add it to the merge order for the closing session.

### 3. Check capacity

Count packages that are `cell:active` against the WIP cap, which defaults to
four (`coordination.md` §Waves and the WIP cap).

- Under the cap: dispatch from the queue.
- At the cap: wait for a merge.
- Over the cap: the dispatch was wrong. Find out how before dispatching again.

### 4. Dispatch

For each package taken from `cell:queued`, highest priority first:

- [ ] Every `dependsOn` branch has merged and been released where release is
      its own step (`working-agreements.md` §Multi-repo sequencing).
- [ ] The `SCOPE.json` block from the package issue is current against what has
      merged since it was written, and is installed for the branch
      (`scope-contract.md` §Resolution order for `SCOPE.json`).
- [ ] The execution profile is resolved and any change from the planned one is
      logged (`coordination.md` §Execution profiles).
- [ ] Any scope-down is logged. It may not widen the lane.
- [ ] The worker starts under the checked-in worker contract
      (`coordination.md` §The worker contract) and in its own worktree.
- [ ] The issue records the branch and the wave.

Log the wave as `coordination.md` §Waves and the WIP cap describes: which
packages went out and which dependency clearing let them go.

### Session log entry

One progress-log entry per session, with names and numbers:

```markdown
## Session — <date> <time> UTC

**Blocked:** <n> handled (<package>: <outcome>, <package>: <outcome>)
**Ready PRs:** <n> approved (<package>)
**Active:** <n> (<package>, <package>)
**Dispatched:** <package>

**Summary:** <movement, exhaustion with counts, or alarm>
```

## Merging in order

Run this in the closing session, over the approved PRs, in dependency order.
The pre-merge checks, the merge steps, merge failures and rollback are in
`merge-procedure.md`; this is only the session-level list.

```
[ ] Re-check CI on every approved PR
[ ] Merge in dependency order, following merge-procedure.md
[ ] Record each merge in the progress log
[ ] Re-run sync-cells.sh so labels follow the merges
```

- A package whose dependency has not merged waits.
- If a rebase changed the head, the evidence stamp is void; the worker re-runs
  and re-stamps (`working-agreements.md` §Evidence is stamped to a sha).
- Time-box each merge to three to five minutes. A merge that passes ten minutes
  means something is wrong: stop and investigate rather than push through.
- After each merge, record the package and merge commit. Any package that was
  waiting only on this one is now a candidate for promotion to `cell:queued`.
- Where packages target several repos, release order is its own concern:
  `working-agreements.md` §Multi-repo sequencing.

## Preparing the next wave

```
[ ] Check the SCOPE.json block of each package likely to start next
[ ] Reorder the queue
[ ] Write the progress-log entry for the day
```

- **Check scope blocks.** For each package likely to start next, confirm its
  `SCOPE.json` still matches the tree after today's merges (paths moved,
  files added) and that `dependsOn` still names the right branches. This saves
  the same checking from the next opening session.
- **Reorder the queue.** Did a new dependency appear, or a priority change?
  Put the highest-priority packages first and make each `dependsOn` visible.
- **Log.** Merged packages, active count, queue counts, and what is prepared.

```markdown
## Session — <date> <time> UTC

**Merged:** <n> (<package>)
**Active:** <n> (<package>, <package>)
**Queue:** <n> cell:queued, <n> cell:blocked
**Prepared for next wave:** <package>
```

## Weekly review

Once a week, spend about ten minutes on the packages that merged:

1. Read their retrospectives (`assets/retrospective-template.md`).
2. Look for repeats: the same kind of blocker, the same scope violation.
3. Update the templates and the `SCOPE.json` defaults those repeats point to.
4. Adjust the process if needed: a longer scope design pass, more CI checks.
5. Tell the team what is working and what is not.

## Troubleshooting

### A package has been active a long time

Check whether the branch has recent commits.

- **No recent commits:** the worker may be stuck. Look for a `BLOCKER.md`. If
  there is none, the package is producing no movement, and the cycle contract
  and stopping condition in `coordination.md` apply.
- **Slow commits:** the package may be larger than its boundary suggested.
  Consider splitting it (`cell.md` §Sizing) as a new package, not by widening
  the live lane.

### Two packages each depend on the other

Work out which dependency is real. Either cut one package differently so the
cycle breaks, or merge one first, rebase the second onto it, and merge the
second. Because dependencies are declared in three places that must agree
(`SKILL.md` §Seven invariants), fix all three.

For a merge that conflicts or a wrong merge, see `merge-procedure.md`.

## When to escalate

Escalate beyond the coordinator when:

- two packages have a genuine, unresolvable dependency conflict;
- a blocker needs an architectural decision or missing context you cannot
  supply;
- several packages fail their tests after merge;
- scope violations are systematic, which points at how lanes are designed
  rather than at one package;
- CI or deploy infrastructure breaks.

To escalate:

1. Write down the context, what you tried and why you are stuck.
2. File a tracker issue and share it with the team.
3. Pause dispatching new packages until it is resolved.
4. Resume with the adjustments the decision calls for, and log them.
