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
contract committed. It prints, per target, the identity fleet commits under:
the `user.name` and `user.email` configured in that target's clone, which the
scope commit and its re-cut carry as author and committer. With `isolateWorkers` on, it also checks that no
`CLAUDE.md`, `CLAUDE.local.md` or `.claude/CLAUDE.md` sits in `worktreesDir` or
an ancestor of it: `worktreesDir` must be outside `$HOME`, or any other
directory with such an ancestor. For each target it prints the base ref and
whether the clone has it.

The base-ref rule: a target's base ref is `origin/<integrationBranch>` when
`targets[].integrationBranch` is set, else `origin/<defaultBranch>`. Launch
reads the standards manifest and `.claude/settings.json` from it, cuts each
worker branch from it, and tells the worker to open its PR against that
branch, so expect those PRs to target the integration branch, not the default
one. `integrationBranch` may not be protected: `main`, `master`, `develop`,
`development`, the target's `defaultBranch`, or a name in the top-level
`protectedBranches` array. `targets[].autoMerge` (default `false`) requires
`integrationBranch`. Either violation is a config error naming the key.

A coordinator session runs cycles on an interval, for example with `/loop`,
and reads each report. The runtime does the mechanical part; the coordinator
decides what the report asks it to decide.

## Reading the report

Every cycle ends in exactly one outcome (the cycle contract):

- **Movement**: named packages with the artifact that proves it (a `dispatch`
  with its branch, a `pr`, a `merged` label, a `verified` stamp from the
  verify stage). Nothing to do.
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
    If the target is verified outside GitHub Actions, set its
    `ci: { "gate": "external", "verifiedBy": "<what verifies it>" }` in
    `fleet.config.json` instead; that is a statement about where proof comes
    from, not a way to silence the alarm.
    If the target's verifier admits one run at a time, add
    `verify: { "kind": "lab-runner", "url": "<loopback url>", "suite": "<id>" }`
    to it (requires `ci.gate` `external`). Its workers then stop at a
    `[VERIFY]: <id>` PR carrying the selection `ci.verifiedBy` says how to list;
    they do not run the verifier, take its lock, or stamp `VERIFIED`. Expect
    `[VERIFY]` PRs from that target, not `[READY]`.
    If a person or a script outside fleet verifies the target, use
    `verify: { "kind": "manual", "suite": "<id>" }` (no `url`; `suite` optional,
    but the worker prompt names it) instead. The worker prompt is the same as
    for `lab-runner`. fleet makes no request:
    the report lists the queue as `queued`, gates first, then oldest, and the
    waiting PRs keep the streak from latching. Verify each PR, comment
    `VERIFIED: <suite> @ <full head sha>` on it, and retitle it `[READY]:`
    (the next cycle retitles it if you do not); it then leaves the queue.
  - `launch-ci-check-failed`: the CI state could not be read (auth, network,
    API error). The launch is refused, never assumed healthy.
  - `launch-identity-missing`: the target clone has no `user.name` or no
    `user.email` configured; the detail names the clone and the missing value.
    Fleet commits the scope under the clone's own identity and never makes one
    up. Run `git -C <localPath> config user.name "<name>"` and
    `git -C <localPath> config user.email "<email>"` with the person whose
    commits these are. Nothing was launched; the dry run and `fleet doctor`
    report the same check. `launch-identity-unreadable` means git could not
    read the config at all; the detail says why.
  - `launch-integration-branch-missing`: the target names an
    `integrationBranch` its local clone has no `origin/` ref for. The detail
    names the branch and the command that creates it from the default branch,
    run in the clone: `git push origin <defaultBranch>:<integrationBranch>`.
    Create it, or remove the key; nothing was launched for that target.
  - `launch-standards-missing`: the target's base ref (as fetched into its
    local clone: `origin/<integrationBranch>`, else `origin/<defaultBranch>`)
    has no standards manifest at
    `targets[].standards.manifest` (default `.claude/standards.json`). Publish
    one on that branch; nothing was launched for that target. Setting
    `"standards": "off"` on the target launches without one, and every
    launched row for it then says `standards: off`.
  - `launch-standards-unreadable`: git could not list or read the default
    branch in the local clone; the detail says which command failed and why.
    Fix the clone or `defaultBranch`.
  - `launch-standards-invalid`: the manifest fails `check-standards.js`; the
    detail lists every defect. Also raised when the worktree's copy differs
    from the one read on the default branch (it changed between the two reads,
    or an adopted branch carries another); the branch is then pushed but no
    worker started. Fix the manifest on the default branch.
  - `launch-hooks-missing`: with `isolateWorkers` on (the default), the
    target's `.claude/settings.json` on its base ref does not
    provide `enforce-scope` or `require-handoff`; the detail names which, or
    says the file is absent, unreadable or not JSON. An isolated worker loads
    no plugin enabled only in your user settings, so those hooks would not
    run. Fix that file either way: wire each hook by path in a `hooks`
    command, or set `enabledPlugins["agentic-work-packages@<marketplace>"]`
    to `true`. Nothing was launched for that target.
  - `launch-plugin-missing`: with `isolateWorkers` on, the standards manifest
    declares a plugin in `plugins[]` that the same settings file does not
    enable as `enabledPlugins["<name>@<marketplace>"]: true`; the detail names
    it. Enable it there.
  - `launch-instructions-leak`: with `isolateWorkers` on, an ancestor of the
    worktree path holds `CLAUDE.md`, `CLAUDE.local.md` or `.claude/CLAUDE.md`;
    the detail names each file. Claude Code loads an instruction file from
    every ancestor of the working directory, so a worktree under `$HOME` would
    read your `~/.claude/CLAUDE.md` despite the isolation. Set `worktreesDir`
    to a directory with no such file in it or any ancestor, outside `$HOME`.
    Nothing was launched; the dry run and `fleet doctor` report the same check.
    `"isolateWorkers": false` in `fleet.config.json` turns off all three
    checks and the isolation with them.
  - `escalation-cap`: a package failed `maxEscalations` times. Read its log
    under `<stateDir>/logs/`, decide whether to split it, widen the plan, or
    re-cut it as a new package. The runtime holds it until you act.
  - `blocker-overdue`: a parked `BLOCKER.md` carries a date that has passed.
  - `verify-not-reverted`: a verifier run finished without reverting the lab,
    so the lab may still hold that PR's change. The fleet is **latched**:
    nothing launches or verifies. Restore the lab, then
    `fleet resume --reason "<what you restored>"`.
  - `verify-unreachable`: the verifier did not answer. The in-flight record is
    kept and read again next cycle; start the runner on its configured port.
  - `verify-refused`: the verifier answered 409 for a reason other than a run
    already going. The reason is commented on the PR, and the PR is skipped
    until its head changes.
  - `verify-bad-sha`: the run record's `verify.headSha` is not a full
    40-character lowercase sha, so it was not stamped. Fix the runner.
  - `verify-pr-missing`: a run finished for a PR that is not in the target's
    PR list (past the page limit). The record is kept; raise `FLEET_PAGE_LIMIT`.
  - `verify-post-failed`, `verify-write-failed`, `verify-redispatch-failed`:
    the POST got an unexpected answer, a PR comment or title edit failed, or a
    failed PR's worker could not be re-dispatched (no closed session on this
    machine). The detail names which.
  - `verify-stale` is reported, not an alarm: the PR head moved during the run,
    the result was discarded, and the PR is posted again.
  - `latched`: three consecutive cycles without movement (configurable). The
    runtime stops starting cycles. Read the last reports, then
    `fleet resume --reason "<what you concluded>"`.
  - `locked`: another cycle is running. Wait.

Each **Launched** row ends in its standards: ` · standards: <check names>
(<n> of <m> rules in lane)`, the checks the worker was told to run and how many
of the manifest's rules overlap its lane, or ` · standards: off` for a target
that launches without a manifest. An `off` row means nothing told the worker
the repo's rules.

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
