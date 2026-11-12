# Cheat sheet: running a program

You run a program of work as one long conversation with a Claude Code
coordinator session. Your messages are short. The session plans, files,
dispatches, watches workers, keeps the tracker current and brings you
decisions. You approve, decide, review and merge.

The left column of each table is the kind of thing you say. The right column is
what the session does in response. The tools it uses are in
[developer-guide.md](developer-guide.md). The rules it works under are in the
`agentic-work-packages` plugin `references/` and the worker contract, and
those govern where this sheet and they differ.

---

## 1. Plan

| You say | The session |
|---|---|
| "Create an implementation plan from the docs in `docs/`. Use the agentic packages skill." | Explores the code, then writes the epic and its packages and gates (`references/epic.md`, `cell.md`, `gate.md`). |
| "Create an epic with a plan for closing these gaps." | Same, starting from a review or a list in the conversation. |
| "File the packages as issues under the epic." | Creates the package and gate issues with parent links, `SCOPE.json` blocks and dependencies. |
| "Install the hooks and worker contract in the repo." | Installs `enforce-scope.js`, `require-handoff.js` and `.claude/worker-contract.md` in each target repo. |
| "Next steps before we begin work?" | Runs the pre-dispatch checklist (`agentic-work-packages` SKILL.md) and reports what is missing. |

## 2. Approve

Nothing dispatches until you approve the plan (`references/epic.md`).

| You say | The session |
|---|---|
| "Give me a link to approve the epic." | Links the epic. You comment `approved`. |
| "Approved. Dispatch wave 1." / "Approve program P and start wave 1." | Labels the first wave `agent-ready` and dispatches it. |
| "Approve P0.4, VP0 and phase 1." | Approves the named packages, gate and phase. |
| "Go, start phase 2 when V1 closes." | Holds phase 2 until the gate's issue closes, then dispatches it. |

## 3. Run

| You say | The session |
|---|---|
| "Continue until blocked." | Dispatches, watches workers, files discovered work and moves to the next wave until it needs you. This is the default mode. |
| "I'm stepping away for 8 hours. Continue until blocked." | The same, after first asking for every decision it can foresee. |
| "Run cycles on a loop." | Runs `fleet cycle --apply` on an interval with `/loop` and reads each report. |
| "Run the dry run." → "Apply the cycle." | One `fleet cycle`, shown first, then applied. |
| "Start P1.2." / "Dispatch it." / "Start both workers." / "Relaunch worker b." | Launches the named packages or workers. |
| "Assign it to worker b." / "Did worker b claim #518?" | Sets the `worker:<id>` label, or checks the claim (`references/multi-account.md`). |

## 4. Monitor

| You say | The session |
|---|---|
| "Status?" | What is running, what landed since the last report, what is waiting on you. |
| "ETA?" / "ETA to complete the epic?" | An estimate from what is left and the pace so far. |
| "Anything for me?" / "Any open PRs?" | What needs your decision or your merge, with links. |
| "Why are we stopped?" / "Why did the worker go quiet?" | Reads the fleet report, the worker log or the `BLOCKER.md`, and says why. |
| "Are the GitHub issues up to date?" | Checks the epic's checkboxes and progress log against merged PRs and fixes the gaps. |
| "What remains to complete the epic?" | Unmerged packages and gates, and what each is waiting on. |

## 5. Decide

| You say | The session |
|---|---|
| "What do you need from me to keep going?" | Lists only the decisions that are yours (below). |
| "Give me each decision one at a time, with options and a recommendation." | Asks them in turn. You answer "a", "1", "option 2", "accept the recommendation". |
| "Read the BLOCKER.md for P2.1." | Summarizes the blocker and its options. |
| "#638: widen the lane." / "Option 1, edit #29 and relaunch it." | Records the decision on the epic, re-cuts the `### SCOPE.json` block in the issue, removes the blocker and relaunches. |
| "You're authorized to use your best judgment on the remaining decisions." | Decides, and records each decision in the epic's decisions log. |

**Yours to decide:** a parked blocker, a latch, a lane cut wrong, a package
that hit `escalation-cap`, a change to a frozen shared interface
(`references/contract-change.md`), merges, and anything that spends beyond the
budget. The session proceeds on everything else.

## 6. Discovered work

Discovered work becomes a new package; a live lane is never widened without
your decision.

| You say | The session |
|---|---|
| "File it." / "File it and start it." / "File, then dispatch." | Writes the package issue under the epic, then dispatches it if told to. |
| "File it, but do not start it." | Files it without the `agent-ready` label. |
| "Hold it until #765 merges." | Files it with that dependency; it dispatches once the PR merges. |
| "Add it to scope." | Adds it to the current package issue's scope, if the package has not launched. |
| "Create an issue for that." | Files a plain issue, not a package. |

## 7. Review and merge

You merge unless you delegate it. The session works from what you report.

| You say | The session |
|---|---|
| "Give me a link to the PR." / "Can I review #452 now?" | Links it, with its CI state and stamp. |
| "Merged." / "#717 merged." / "Both merged." | Ticks the epic, updates the progress log, promotes packages whose dependencies are now met, and dispatches. |
| "Close #685, tick it, start P0.1." | Exactly that. |
| "#709 has conflicts." / "#83 fails CI." | Gets the branch fixed, re-tested and re-stamped. |
| "Merge it when green." / "Keep going, merge them as they go green." | Waits for green CI, then merges, and keeps going. |
| "Kill any queued CI for things already merged." | Cancels those runs. |
| "/code-review" | Reviews the PR or branch. Findings never approve or block on their own. |

## 8. Visual review

| You say | The session |
|---|---|
| "Can I see this in the local env?" / "Update local and restart the env." | Pulls, rebuilds and restarts the local stack, and gives you the URL. |
| "Walk me through the visual review." / "Give me the testing steps one at a time." | Gives one step, waits for your result, then the next. |
| "Step 5 fails: no documents." | Files or fixes it, depending on whether it is inside a live package's lane. |

## 9. Capacity and cost

| You say | The session |
|---|---|
| "How can we speed this up?" / "Would more agents help?" | Proposes raising the WIP cap, adding workers, moving work to another machine or the cloud, or changing models. |
| "Use the other machine." / "I need it back in 15 minutes." | Moves workers onto it, or drains them off it. |
| "Switch to Sonnet for work that can safely run on Sonnet." | Sets the model tier per package. |
| "We're spending too much on GitHub Actions. Run the tests locally." | Moves test runs off CI and reports what it changed. |
| "Clean up the merged worktrees." | Removes merged, clean worktrees and their branches. |

## 10. Resume

Nothing a session needs is held only in a previous session. The tracker,
`HANDOFF.md`, `BLOCKER.md` and the fleet state carry it.

| You say | The session |
|---|---|
| "We're trying to finish this epic: <url>. Read it and its issues and tell me how to resume." | Rebuilds state from the epic logs, `cell:*` labels, branches, handoffs, blockers and `fleet status`, then proposes the next step. |
| "I had to switch accounts. Two epics were in flight: <url>, <url>." | The same for both, plus how to split the remaining work across machines and accounts. |
| "Resume the fleet. I concluded <x>." | After a latch: `fleet resume --reason "<x>"`. |

## 11. Close out

| You say | The session |
|---|---|
| "Is #657 done? Tick and close. Check other open issues that should be closed." | Checks the success criteria, closes the epic and any finished stragglers. |
| "What needs to get merged into develop?" / "Create a PR to merge develop into main." | Lists what is pending, then opens the release PR. |
| "Summarize what we added." | A summary of the program's delivered capabilities. |

---

## What you expect without asking

The `references/` already require these:

- The epic's checklist is ticked and its progress log updated as packages
  land, so progress can be followed on the tracker (`references/epic.md`,
  `references/coordination.md`).
- A PR goes into the merge order only with green CI (`references/coordinator-checklists.md`).
- Decisions that constrain later work go in the epic's decisions log.

These are not yet written in the `references/`:

- A PR is not reported as ready while its CI is red.
- Decisions come all at once when you ask what is needed, and one at a time
  with options and a recommendation when you work through them.
- A worker that has been quiet for a long time is reported, not left silent.
- A visual handoff has already been checked by the session; you are not the
  first tester.
