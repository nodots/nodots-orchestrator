---
name: fleet
description: Drive a fleet of autonomous worker agents against an agentic-work-packages program with the `fleet` runtime: run one coordination cycle (sync labels, promote, assign, launch local workers in worktrees, reap, report), read the Movement/Exhaustion/Alarm report, and act on alarms, parked blockers and the stop latch. Use when asked to run, babysit, resume or diagnose a fleet, or to dispatch a work package to a worker session.
---

# fleet

`fleet` is the coordinator's runtime for the `agentic-work-packages` model. One
`fleet cycle` is one pass of the coordinator cycle in `coordination.md`:

```
sync-cells.sh --apply  →  promote  →  assign-cells.sh --apply  →  launch  →  reap  →  report
```

It writes two things to the tracker (`cell:queued` on promotion, and the
`worker:<id>` labels through `assign-cells.sh`) plus one report comment on the
epic per cycle. Everything else it reads fresh each pass. Locally it keeps one
state file: which process runs which package, dispatch history, the
no-movement streak.

## Running it

```bash
FLEET=$(ls -d ~/.claude/plugins/cache/*/fleet/*/bin/fleet.js | sort -V | tail -1)   # the installed copy
node "$FLEET" cycle --config fleet.config.json          # dry run: nothing written
node "$FLEET" cycle --config fleet.config.json --apply  # one real pass
```

`$CLAUDE_PLUGIN_ROOT` is set only inside the plugin's own hooks, not in a
coordinator session, so resolve the path as above or from a checkout of
`nodots-orchestrator` (`plugins/fleet/bin/fleet.js`).

`fleet.config.json` lives with the program (see `fleet.config.example.json` in
this plugin). `fleet doctor` checks binaries, the plugin scripts, labels, the
epic, and that each target repo has the scope and handoff hooks and the worker
contract committed.

A coordinator session runs cycles on an interval, for example with `/loop`,
and reads each report. The runtime does the mechanical part; the coordinator
decides what the report asks it to decide.

## Reading the report

Every cycle ends in exactly one outcome (the cycle contract):

- **Movement**: named packages with the artifact that proves it (a `dispatch`
  with its branch, a `pr`, a `merged` label). Nothing to do.
- **Exhaustion**: nothing was dispatchable; the counts say why (queued, active,
  in review, blocked, live sessions, free WIP slots). Nothing to do unless the
  counts look wrong.
- **Alarm**: something the coordinator must act on. The `code` says what:
  - `sync-failed`, `assign-failed`, `issues-failed`: the tracker read failed or
    was truncated; nothing was launched. Fix the cause (page limit, auth) and
    run again.
  - `launch-claim`: the branch already exists on origin with no local worktree.
    Another worker (or account) owns it. Do not take it over; find out who.
  - `launch-push`: the plain push was rejected. Same meaning as `launch-claim`.
  - `unlaunchable`: the issue's `### SCOPE.json` block is missing, invalid, or
    names an empty lane. Fix the issue body; the runtime never edits it.
    A `cheapest` package with no `execution.verifiedBy` is refused the same way.
  - `launch-ci-disabled`: the target repo has no enabled CI workflow. Enable
    one; nothing was launched for that target.
  - `launch-ci-stale`: the target's default branch has no workflow run inside
    `ciMaxAgeDays` (default 14). Get CI running again, or raise the window.
  - `launch-ci-check-failed`: the CI state could not be read (auth, network,
    API error). The launch is refused, never assumed healthy.
  - `escalation-cap`: a package failed `maxEscalations` times. Read its log
    under `<stateDir>/logs/`, decide whether to split it, widen the plan, or
    re-cut it as a new package. The runtime holds it until you act.
  - `blocker-overdue`: a parked `BLOCKER.md` carries a date that has passed.
  - `latched`: three consecutive cycles without movement (configurable). The
    runtime stops starting cycles. Read the last reports, then
    `fleet resume --reason "<what you concluded>"`.
  - `locked`: another cycle is running. Wait.

**Parked** packages are workers that stopped with a `BLOCKER.md` carrying a
known `Kind`. They are yours to resolve per `coordination.md` §`BLOCKER.md`;
the runtime will not relaunch them while the file exists. To resume one:

1. Record the decision on the epic (decisions log).
2. If the lane was cut wrong, re-cut it **in the package issue's `### SCOPE.json`
   block**. The issue is the source of truth; on relaunch the runtime copies that
   block over the committed `SCOPE.json` and pushes it as `<ID>: scope re-cut`.
   Check `forbiddenPaths` as well as `allowedPaths`: a path that is in both
   cannot be worked, and the runtime now refuses such a lane as `unlaunchable`
   instead of launching a worker that the hook will deny.
3. Remove the `BLOCKER.md` from the branch (it may be at the repo root or in
   `.agentic/cells/<branch>/`) with a commit and a plain push.
4. The next `cycle --apply` reaps the session as `unparked` and relaunches it
   at the same tier, as a new dispatch with reason `unparked`. In the JSON
   report the launch carries `"adopted": true` (existing worktree) and
   `"recut": true` when the scope was rewritten. If the package already has a
   PR in any state, the session is closed with outcome `pr` instead and no
   launch is requested. A PR counts for a package only when its head branch
   equals the package branch; a package id or issue reference in a title or
   body never matches.

A package that stops again with a new `BLOCKER.md` is parked again and needs a
second decision; nothing escalates it for you.

Parked packages count as no movement. A fleet with nothing but parked work
latches after `noMovementLimit` cycles, and the latch reason names them; that
is the runtime handing the queue back to you, not a fault.

## Rules the runtime enforces, and the ones it leaves to you

Enforced: one launch path; plain push as the claim; no `--force`; no launch
onto a branch that exists; no relaunch of a package with a PR or a parked
blocker; `SCOPE.json` copied verbatim from the issue; `--permission-prompts
none` so a worker can never wait on a prompt; a budget cap per session; a
wall-clock timeout with SIGTERM then SIGKILL.

Left to you: whether a lane is cut right (the runtime refuses only empty or
malformed lanes), what to do with a parked blocker, whether to resume after a
latch, and binding a worker id to an account for `external` workers
(`multi-account.md`).

## What it does not do

It does not launch, signal or read another account's session. Workers with
`mode: external` are labeled and observed only; those accounts run
`fleet claim` (Phase B) or dispatch by hand. `mode: cloud` is a seam that
reports "not implemented" until the cloud spike is done. It never edits an
issue body or a `SCOPE.json`, never hand-sets a `cell:*` label, and never
reads `HANDOFF.md` to decide anything.
