# fleet

Coordinator runtime for the `agentic-work-packages` plugin. One command, one
pass:

```
fleet cycle --apply
  lock → sync-cells.sh --apply → promote → assign-cells.sh --apply → reap → verify → launch → report → unlock
```

- **sync** derives every `cell:*` label from branches, PRs and `BLOCKER.md`
  (the plugin's script; fleet reads its state through `--emit-state`). It runs
  with `--epic <epic>`, so only the config's epic's packages are derived.
- **promote** adds `cell:queued` to an `agent-ready` package once every
  `dependsOn` branch has a merged PR.
- **assign** hands the epic's queued packages to worker ids as `worker:<id>`
  labels, within the WIP cap and the contract-change holds (the plugin's
  script).
- **launch**, for each queued package owned by a local worker id: a git
  worktree on the package branch, the issue's `SCOPE.json` committed as
  `<ID>: scope`, a plain push as the claim, then a detached
  `claude -p … --permission-prompts none --max-budget-usd …` in the worktree.
  Before any of that, launch refuses a target with no enabled CI workflow
  (`launch-ci-disabled`), no workflow run on its default branch inside
  `ciMaxAgeDays` (default 14; `launch-ci-stale`), or CI state it cannot read
  (`launch-ci-check-failed`). A package on the `cheapest` tier with no
  `execution.verifiedBy` is `unlaunchable`. Blast radius is not checked.
  A target whose changes are verified outside GitHub Actions declares
  `"ci": { "gate": "external", "verifiedBy": "..." }` in `fleet.config.json`;
  launch then skips the GitHub Actions check for it, tells the worker what
  verifies its work, and records the gate on the session and in the report.
  `verifiedBy` is required with `external`, so the exemption is never silent.
  A target whose verifier admits one run at a time also declares
  `"verify": { "kind": "lab-runner", "url": "http://127.0.0.1:<port>", "suite": "<id>" }`.
  `url` must be loopback, `suite` must match `^[A-Za-z0-9_-]+$`, and `ci.gate`
  must be `external`; anything else is a config error. A target verified by a
  person or a script outside fleet declares `"verify": { "kind": "manual" }`
  instead: it needs no `url` (one is refused, since nothing is requested), and
  `suite` is optional. The worker prompt is the same for both kinds; it names
  the suite, so set one (without it the prompt reads `suite undefined`).
  A worker on that target opens its PR titled `[VERIFY]: <id>`, never
  `[READY]`. It does not run the verifier, claim any lock it uses, or post a
  `VERIFIED` stamp, and it pastes into the PR body the selection its target's
  tooling lists, as `ci.verifiedBy` describes.
- **reap** classifies finished sessions: PR ⇒ movement; `BLOCKER.md` with a
  known Kind ⇒ parked for the coordinator; silent or failed ⇒ escalate one
  model tier up, up to `maxEscalations`. A PR belongs to a package only when
  its head branch equals the package branch (title and body are ignored). A
  parked session whose blocker is removed is relaunched only if the package
  has no PR in any state; otherwise it is closed as `pr`.
- **verify** runs for each target with `verify`, after reap and before launch,
  and keeps one verifier run in flight per target (`src/verify.js`):
  - A run recorded in `state.json` (`verify.<repo>.inFlight`) is read with
    `GET <url>/runs/<id>`. Unfinished, it is left; it counts as live, so
    waiting on it never raises the no-movement streak.
  - With nothing in flight, the next `cell:awaiting-lab` PR is posted with
    `POST <url>/<suite>/verify {"pr": n}`: gates (`V<n>`) first, then packages
    whose `dependsOn` all merged, then the oldest. A PR is skipped at the head
    its last run failed or was refused at.
  - Pass (`exitCode` 0, `verify.reverted` true, `verify.headSha` a full
    40-character sha equal to the PR head): a `VERIFIED: lab-impacted @ <sha>`
    comment with a summary of the run, then `[VERIFY]:` is retitled
    `[READY]:`. Movement `verified`.
  - Fail (`exitCode` not 0): the summary is commented on the PR and the
    package's worker is re-dispatched at the same tier with reason
    `verify-failed: <first unexpected test>`. It counts toward
    `maxEscalations`; at the cap the package is held with `escalation-cap`.
  - A head that moved since the POST discards the result (`verify-stale`);
    the PR is posted again next cycle.
  - A 409 `a run is already going` is retried next cycle. Any other 409 is
    commented on the PR, raises `verify-refused`, and the next PR is tried.
  - `verify.reverted` not true raises `verify-not-reverted` and **latches the
    fleet**: nothing launches or verifies until `fleet resume --reason <text>`.
  - An open `[READY]:` PR on a verify target with no stamp at its head (a push
    after the stamp) is retitled `[VERIFY]:` and queued again. A `[VERIFY]:` PR
    with a stamp at its head is retitled `[READY]:`.
  - When the target's PR list fails (`pulls-failed`), the stage skips the
    target and keeps the record.
  - `verify-unreachable` and `verify-pr-missing` (the record is kept),
    `verify-refused`, `verify-not-reverted`, `verify-bad-sha`, `verify-post-failed`,
    `verify-write-failed` and `verify-redispatch-failed` make the cycle an
    alarm. `verify-stale` does not.
  - A dry run makes no POST, comment or title edit; it reports what it would
    do. `fleet launch <issue>` runs no verify stage.
  - A `manual` target makes no request and keeps no run in flight. The stage
    reports its `cell:awaiting-lab` PRs as `queued`, in the order above; only
    a failed title edit (`verify-write-failed`) can alarm. Its waiting PRs count as live for the streak, so a
    fleet waiting on a person does not latch. The outside verifier comments
    `VERIFIED: <suite> @ <full head sha>` and retitles `[READY]:`; a stamp
    without the retitle is retitled by the stage, as for `lab-runner`. Either
    way the PR leaves the queue.
- **report** posts one Movement / Exhaustion / Alarm comment on the epic, with
  a marker so a re-post is a no-op, and keeps the no-movement streak that
  latches the fleet after `noMovementLimit` cycles. For a config with a verify
  target the counts add `awaiting-lab` and `verifying`; every other report is
  unchanged.

A cycle acts on one epic: the packages whose header line says
`**Part of** #<epic>`, the same rule `sync-cells.sh --epic` applies. Other
programs in the same host repo are neither synced, promoted, assigned nor
launched: fleet passes `assign-cells.sh` the epic's open packages through
`--state`, so the WIP cap counts only the epic's in-flight packages.
`fleet doctor` prints how many open packages in the host repo belong to the
epic and how many do not. One limit follows:

- A `dependsOn` branch that belongs to another epic is never seen as merged,
  because promotion reads merged branches from the epic's sync state. Keep
  dependencies inside the epic.

No daemon. State is the tracker plus `<stateDir>/state.json` (sessions,
dispatch history, streak), written atomically. A crash mid-cycle is recovered
on the next pass from the tracker and the worktrees.

## Install

```bash
claude plugin marketplace add nodots/nodots-orchestrator
claude plugin install fleet@nodots-plugins
```

Requires `agentic-work-packages` ≥ 1.4.0 beside it (same marketplace), `git`,
`gh` authenticated to the host and target repos, and `claude` ≥ 2.1.259 (for
`--permission-prompts`).

## Use

```bash
cp "$PLUGIN/fleet.config.example.json" fleet.config.json   # edit for the program
node "$PLUGIN/bin/fleet.js" doctor
node "$PLUGIN/bin/fleet.js" cycle            # dry run
node "$PLUGIN/bin/fleet.js" cycle --apply    # one pass
node "$PLUGIN/bin/fleet.js" status
node "$PLUGIN/bin/fleet.js" resume --reason "reviewed the last three reports; queue is real"
```

`skills/fleet/SKILL.md` tells a coordinator Claude session how to drive it and
what each alarm asks for.

## Approval enforcement

`approvalEnforcement` in `fleet.config.json` is `off` by default. While `off`,
no check added by the review epic blocks any merge. Set it per project; it is
not turned on for this repository.

| Value               | Mechanism                                  | Needs                                                                 |
|---------------------|--------------------------------------------|-----------------------------------------------------------------------|
| `off`               | none                                       | nothing                                                               |
| `branch-protection` | required pull request review on the default branch | a plan that offers branch protection for the repo's visibility |
| `ruleset`           | a branch ruleset with a `pull_request` rule | a plan that offers rulesets for the repo's visibility                |

Both mechanisms require one approving review. `approvalPayload(config)` in
`src/config.js` returns the request body, and `approvalGate(config, pr)`
returns `{ blocked, mechanism, reason }` for a PR: a PR with no human approval
is blocked when the setting is on and not blocked when it is off. A bot
approval does not count.

Turn it on for a project:

```bash
# 1. set "approvalEnforcement": "branch-protection" (or "ruleset") in fleet.config.json
# 2. apply the mechanism, from the target repo; check the account first
gh api -X PUT repos/OWNER/REPO/branches/BRANCH/protection --input protection.json
gh api -X POST repos/OWNER/REPO/rulesets --input ruleset.json
```

Write the payload to the `--input` file with
`node -e "const c=require('./src/config').loadConfig('fleet.config.json'); console.log(JSON.stringify(require('./src/config').approvalPayload(c)))"`.
Fleet does not call these endpoints itself. The PUT replaces any protection
already set on that branch, so read it first with `gh api repos/OWNER/REPO/branches/BRANCH/protection`.

Where a mechanism is unavailable:

- Branch protection on a repository whose plan lacks it: the API answers 403.
  `nodots/nodots-orchestrator` is in this state, which is why enforcement ships
  off. Rulesets have not been tried on it. Whether a given plan offers each mechanism is
  GitHub's to say; check the current plan table at
  https://docs.github.com/en/get-started/learning-about-github/githubs-plans
  before relying on either.
- With neither available, `approvalEnforcement` cannot be enforced by the
  forge. Leave it `off`; fleet adds no check of its own that blocks a merge.

## Layout

```
bin/fleet.js        CLI: cycle, launch, reap, status, resume, doctor
src/config.js       fleet.config.json, defaults, GH_BIN/GIT_BIN/CLAUDE_BIN seams
src/exec.js         argv-array process execution, detached spawn, liveness
src/scripts.js      runs sync-cells.sh and assign-cells.sh, parses their rows
src/tracker.js      every gh call the runtime makes
src/scope.js        SCOPE.json from the issue body; validation; slugs and paths
src/promote.js      pure promotion rule
src/launch.js       worktree + scope commit + plain push + detached claude -p
src/reap.js         liveness, timeout, pure classify()
src/store.js        atomic state file, cycle lock
src/report.js       report JSON, rendering, idempotent post
src/cycle.js        the pass
tests/*.test.sh     fixture tests (bash + node builtins; gh and claude stubbed, git real)
```

## Tests

```bash
for t in plugins/fleet/tests/*.test.sh; do bash "$t"; done
```

`cycle.test.sh` runs the whole pass against a bare git remote, the real plugin
scripts, a stateful `gh` stub and a scripted `claude` stub. CI runs all of them.

## Not yet

`mode: cloud` (workers on `claude --cloud`) and `fleet claim` for external
accounts are Phase B; both are seams that report "not implemented" today.
