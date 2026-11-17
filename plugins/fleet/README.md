# fleet

Coordinator runtime for the `agentic-work-packages` plugin. One command, one
pass:

```
fleet cycle --apply
  lock → sync-cells.sh --apply → promote → assign-cells.sh --apply → reap → verify → review → launch → report → unlock
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
  The scope commit, and the `<ID>: scope re-cut` of an adopted worktree, are
  made under the human identity configured in the target clone
  (`git -C <localPath> config user.name` and `user.email`), as author and
  committer. Fleet never makes one up: a clone with either value empty is
  refused `launch-identity-missing`, in the dry run as in the applied cycle,
  and the alarm names the clone and the two `git config` commands that fix it.
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
  model tier up, up to `maxEscalations`. A package whose issue lacks
  `agent-ready` is not re-dispatched by any of these (unpark, verify or review
  failure, escalation, relaunch): the request is held, reported under
  **Held**, and goes ahead in the first cycle after the label is back. To
  finish a package by hand, remove `agent-ready` first. A PR belongs to a package only when
  its head branch equals the package branch (title and body are ignored). A
  parked session whose blocker is removed is relaunched only if the package
  has no PR in any state; otherwise it is closed as `pr`. A running session
  whose process is gone and which left no exit file was killed from outside
  (the launcher's wrapper writes the exit file on every exit it survives): it
  is reaped as `vanished`, relaunched at the same attempt under alarm
  `worker-vanished` (package, pid, how long it lived, log size), and is not
  movement, so the no-movement streak still rises. A session reap killed on
  timeout is not vanished; it escalates as `timeout`. A second vanishing of the
  same package within `sessionTimeoutMinutes` holds it with
  `worker-vanished-repeat` and launches nothing; like `escalation-cap`, the
  hold stays until the coordinator acts.
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
- **review** runs after verify and before launch, for a config with
  `reviewers` (`src/review.js`; see [Review](#review)). Each
  `cell:awaiting-reviewer` PR gets one reviewer in flight, read-only in a fresh
  worktree at its head. A pass posts `REVIEWED: <name> @ <sha>`; a fail
  comments the findings and re-dispatches the worker.
- **report** posts one Movement / Exhaustion / Alarm comment on the epic, with
  a marker so a re-post is a no-op, and keeps the no-movement streak that
  latches the fleet after `noMovementLimit` cycles. For a config with a verify
  target the counts add `awaiting-lab` and `verifying`; for a config with
  `reviewers`, `awaiting-reviewer` and `reviewing`, and the report has a
  Review section. Every other report is unchanged.

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

Running a cycle from a supervisor requires the workers to outlive it. Under
systemd, set `KillMode=process` on the unit: the default
`KillMode=control-group` kills every worker a `Type=oneshot` cycle launched as
soon as the cycle exits, and each later cycle reports `worker-vanished`.
`DAEMON.md` has a complete unit.

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

## Installing the worker files

A target repo commits its own copies of the worker files, because an isolated
or cloud worker sees only what the repo commits:

- `hooks/enforce-scope.js`, `hooks/require-handoff.js` and
  `hooks/standards-preamble.js` from `pluginRoot`, as `.claude/hooks/`;
- `skills/agentic-work-packages/assets/worker-contract.md`, as
  `.claude/worker-contract.md`;
- each hook registration in `assets/settings-snippet.json`, in
  `.claude/settings.json`. A registration that is missing is added; every other
  key and entry is kept. A target without the file gets the snippet.

`fleet install` writes them:

```bash
node "$PLUGIN/bin/fleet.js" install --target acme/api           # dry run
node "$PLUGIN/bin/fleet.js" install --target acme/api --apply
```

The dry run compares each file with the target's base ref (the base-ref rule
below) and lists it as `add`, `update` or `same`. It writes nothing.

`--apply` fetches origin, then cuts
`chore/install-agentic-work-packages-<version>` from the base ref in a
worktree under `worktreesDir`, writes the files, and makes one commit under
the clone's `user.name` and `user.email`. A clone without them is refused
`launch-identity-missing`, as launch refuses it. It pushes the branch, removes
the worktree and the local branch, and prints the `gh pr create --base <base
branch>` command. It opens no PR. When every file is `same`, it creates no
branch and exits 0. When the branch already exists on origin, it is refused
until that PR is merged or closed and the branch deleted. An unknown
`--target` exits 64 and names the configured targets.

`fleet doctor` compares each installed file on the base ref with the plugin's
copy. A file that differs or is missing is a `FAIL` naming the file and
`fleet install --target <repo>`. A `.claude/settings.json` without one of the
snippet's registrations is a `FAIL` naming the event.

## Integration branch

A target may name an integration branch:

```json
{ "repo": "acme/api", "localPath": "../api", "defaultBranch": "main",
  "integrationBranch": "integration/program-c", "autoMerge": false }
```

The base-ref rule: a target's base ref is `origin/<integrationBranch>` when it
sets one, else `origin/<defaultBranch>`. Launch reads the standards manifest
and `.claude/settings.json` from the base ref, cuts each worker branch from
it, and tells the worker to open its PR against that branch. A target without
`integrationBranch` behaves exactly as before. CI freshness is still read on
`defaultBranch`.

- `integrationBranch` (string, optional) must not be protected. The protected
  names are `main`, `master`, `develop`, `development`, the target's own
  `defaultBranch`, and every name in the top-level `protectedBranches` (a
  string array, default `[]`). A protected name is a config error naming
  `targets[<i>].integrationBranch`.
- `autoMerge` (boolean, default `false`) is a config error naming
  `targets[<i>].autoMerge` when set to `true` without `integrationBranch`.
- When the local clone has no `origin/<integrationBranch>`, launch is refused
  `integration-branch-missing`, before any worktree exists. The alarm names
  the branch and the command that creates it, run in the clone:
  `git push origin <defaultBranch>:<integrationBranch>`.
- `fleet doctor` prints each target's base ref and whether it exists.

### The merge stage

With `autoMerge: true`, each cycle runs the merge stage (`src/merge.js`) after
verify and review and before launch. It looks at every open PR of the epic's
packages on the target, read fresh with `gh pr view`:

1. **Protected first.** A PR whose base is protected (the list above: `main`,
   `master`, `develop`, `development`, the target's `defaultBranch`,
   `protectedBranches`) is never merged. The stage raises
   `merge-protected-refused` and reads nothing else for it. This check comes
   before any other.
2. A PR whose base is any other branch than `integrationBranch` is skipped.
3. **The merge condition**, checked in order. The first one unmet is named in
   the report, and the PR stays open:
   - a current `VERIFIED` stamp at the head (`stamp.js` `currentStamp`);
   - the target's review policy met, `reviewMet(policy, currentReviews(pr))`,
     when `stamp.js` exports `reviewMet`. Without it, the check is skipped and
     each note says `review not checked`;
   - `gh pr checks` all green: every check `pass` or `skipping`. A PR with no
     checks reported is not green;
   - `mergeable` is `MERGEABLE`.
4. **Merge** with `gh pr merge <n> --merge --match-head-commit <head>`, where
   `<head>` is the sha the condition was checked at. A push after the checks
   makes GitHub refuse the merge, so an unchecked head is never merged. A
   merge is movement `merged`, with the merge commit sha. A failed merge
   raises `merge-failed` with gh's message and is not retried this cycle.

The dry run makes every read and no merge. Its report lists the PRs that
would merge under **Merged** (`would-merge`), and every other PR under
**Not merged** with the reason.

The residual: fleet cannot see the GitHub branch-protection rules on the
integration branch. A rule that blocks the merge, such as a required review
from a code owner, shows only as `merge-failed`.

## Standards

A target's `.claude/standards.json` is its standards manifest: the check
commands a worker runs before it opens a `[READY]` PR, and the rule documents
it reads before it changes code under them. The target repo owns the file; the
contract and every validation rule are in
[`references/standards.md`](../agentic-work-packages/skills/agentic-work-packages/references/standards.md),
and the plugin's `check-standards.js` is the one validator.

Launch requires a valid manifest on the target's base ref (its default branch,
or its integration branch when it names one; S1.2), as it
requires enabled CI. `"standards": "off"` on a target in `fleet.config.json`
disables that requirement for that target; it is the one exception, and it is
reported.

Workers read their instructions from the target repo only. `isolateWorkers`
in `fleet.config.json` (default `true`) launches each worker with
`--setting-sources project,local`, which excludes the operator's user
settings, the plugins enabled only there, and the user instruction file. A
worker's hooks then have to come from the target's own `.claude/settings.json`,
so with isolation on, launch reads that file from the base ref and
refuses the launch in two cases (S2.1):

- `hooks-missing`: `enforce-scope` or `require-handoff` is not provided. Each
  counts as present when a hook `command` in that file names its script by
  path (for example `node "$CLAUDE_PROJECT_DIR/.claude/hooks/enforce-scope.js"`),
  or when `enabledPlugins["agentic-work-packages@<marketplace>"]` is `true`
  there, for any marketplace. An absent, unreadable or non-JSON file is refused
  the same way.
- `plugin-missing`: a plugin in the manifest's `plugins[]` is not enabled there
  as `enabledPlugins["<name>@<marketplace>"]: true`. A target with
  `"standards": "off"` has no manifest, so this check has nothing to read.

The flag does not keep out an instruction file in an ancestor of the worktree.
Claude Code loads `CLAUDE.md` and `.claude/CLAUDE.md` from every ancestor of
the working directory as project instructions, so a worktree under `$HOME`
loads the operator's `~/.claude/CLAUDE.md`. `worktreesDir` must therefore be a
directory with no `CLAUDE.md`, `CLAUDE.local.md` or `.claude/CLAUDE.md` in it
or in any ancestor, which in practice means outside `$HOME`. With isolation
on, launch walks the ancestors of the worktree path, from its parent to `/`,
and refuses the launch in a third case (S2.2):

- `instructions-leak`: an ancestor holds one of those files. The alarm names
  each file found. The dry run reports it, and `fleet doctor` runs the same
  check on `worktreesDir`.

`"isolateWorkers": false` drops the flag and all three checks, and workers
inherit the operator's user settings again.

### Allow rules

A target's `permissions.allow` rules should name the commands its packages and
standards checks run, by path, such as `Bash(bash scripts/*)` or
`Bash(node scripts/*)`. A wildcard over an interpreter or a container runtime
lets a worker run anything through it, outside its lane included.
`fleet doctor` reads each target's `.claude/settings.json` on
`origin/<defaultBranch>` and prints one `WARN` line per allow rule of the form
`Bash(<name> *)` or `Bash(<name>:*)`, where `<name>` is one of `node`,
`python`, `python3`, `bash`, `sh`, `zsh`, `pwsh`, `docker`, `podman`, `npx`,
`deno`, `bun`, `ruby`, `perl`, `sqlcmd`, `psql` or `mysql`. The line names the
rule and why it is broad. A settings file that cannot be read or is not JSON
gets a `WARN` saying its rules were not checked. A `WARN` does not fail doctor
or refuse a launch. See
[`references/scope-contract.md`](../agentic-work-packages/skills/agentic-work-packages/references/scope-contract.md).

`fleet standards init` drafts a manifest from what the clone already has:

```bash
node "$PLUGIN/bin/fleet.js" standards init --target acme/api           # print the draft
node "$PLUGIN/bin/fleet.js" standards init --target acme/api --write   # write it to the clone
```

- `--target` must be one of `targets[]`; the draft is built from its
  `localPath`.
- Checks come from `package.json` `scripts`: each of `lint`, `typecheck` and
  `build` found there becomes a check that runs that script with the package
  manager, and `test` becomes the package manager's test command, in that
  order. With
  no `package.json`, `checks[]` is empty and the draft does not validate: the
  command does not guess a check it cannot see, and the notes say what to add.
- Rules are `CLAUDE.md`, `CONTRIBUTING.md` and `AGENTS.md`, where present at
  the root, each with `"check": null`. `.claude/worker-contract.md` is never a
  rule. The draft has `version` 1, no `preamble` and no `plugins`.
- The draft JSON goes to stdout and the notes to stderr. The draft is then
  validated with `check-standards.js` against the clone's tracked files: exit 0
  when it validates, 1 when it does not, with the defects on stderr.
- `--write` writes `<localPath>/.claude/standards.json` and refuses, with exit
  1, when that file exists. The command never stages, commits or pushes; review
  the file and commit it yourself.

## Review

A target repo asks for independent review with the `review` key of its
`.claude/standards.json`: `{"passes": <n>}`, the number of distinct reviewers
whose `REVIEWED` stamp a PR needs at its head. The sync holds a verified PR
short of that at `cell:awaiting-reviewer`. Fleet meets the policy with the
reviewers in `fleet.config.json`:

```json
"reviewers": [
  { "name": "claude-sonnet-plan",
    "argv": ["sh", "-c", "claude -p --model sonnet --permission-mode plan --output-format text < \"$1\" > \"$2\"", "reviewer", "{prompt}", "{out}"],
    "timeoutMinutes": 20 }
]
```

- `name` matches `^[A-Za-z0-9_.-]+$` and is the name on the stamp. Names are
  unique.
- `argv` is a non-empty array of strings, the command first. In each element,
  `{prompt}` is replaced by the path of the prompt file, `{worktree}` by the
  reviewer's worktree, and `{out}` by the path the verdict is read from. There
  is no shell unless the command is one, as in the example.
- `timeoutMinutes` defaults to 20.
- A reviewer is any command. The example is `claude -p` on a model other than
  the workers', in plan mode, reading the prompt on stdin and writing its final
  answer to `{out}`. A command from another vendor is configured the same way;
  fleet names none and requires none.
- A target whose manifest has a `review` policy, in a config with no
  `reviewers`, fails validation naming the target: the cycle raises
  `config-invalid` and exits 64 before it promotes, assigns, reaps or launches
  anything. The policy lives in the target repo, so this is checked once the
  sync has read it, not when the config is loaded.

Each cycle, for each `cell:awaiting-reviewer` PR with no review in flight,
the stage picks the first reviewer in config order with no current stamp at
the head and no failure recorded there. It fetches the clone, adds a worktree
under `<worktreesDir>/.review/` detached at the PR head, writes the prompt file
under `<stateDir>/review/`, and spawns `argv` detached in the worktree, as
launch spawns a worker. The run is recorded in `state.json` as
`review.<repo>.inFlight[]`: `{ pr, reviewer, headSha, issue, pid, startedAt, ... }`.
At most one reviewer per PR is in flight. A review in flight is live work, so
waiting on it does not raise the no-movement streak.

The prompt file holds a brief, the package issue (title and body), the checks
of the target's standards manifest on its base ref, and
`git diff <base>...HEAD`. The brief says the change is presumed wrong until
shown otherwise; each defect is reported with file, line, claim and evidence;
the reviewer writes only the JSON verdict to `{out}` and changes no file. The
verdict:

```json
{"verdict": "pass", "findings": [{"file": "src/a.js", "line": 12, "claim": "...", "evidence": "..."}]}
```

`verdict` is `pass` or `fail`. Every finding has a non-empty `file`, `claim`
and `evidence` and an integer `line` of 1 or more. A `fail` has at least one
finding. A `pass` lists what it checked.

When the reviewer has exited:

- **Read-only check.** Before the spawn, fleet records the worktree's HEAD and
  `git status --porcelain`. A moved HEAD or any difference after the exit
  discards the verdict and raises `review-wrote`, naming the reviewer. This is
  checked for any command; no reviewer flag is parsed. **It does not see
  writes outside the worktree**: a reviewer that pushes, writes to the tracker
  or edits another path is not caught by it. Run reviewers under a permission
  mode or an account that cannot do those things.
- **A moved head**, or a PR no longer open: `review-stale`; nothing is stamped.
- **Missing or invalid JSON**: `review-invalid`; nothing is stamped.
- **A timeout** (still running after `timeoutMinutes`): the process group is
  killed and `review-timeout` raised; nothing is stamped.
- **Pass** at the current head: a PR comment whose first line is
  `REVIEWED: <name> @ <sha>`, then the findings it checked. Movement
  `reviewed`. The next sync counts it toward the policy.
- **Fail**: the findings are commented on the PR, the head is recorded in
  `review.<repo>.failed`, and the worker is re-dispatched at the same tier with
  reason `review-failed: <first claim>`, through the path a verify failure
  takes. It counts toward `maxEscalations`.

A reviewer that failed, wrote, timed out or gave no valid verdict at a head is
not run again at that head; the next reviewer in config order may be. The
worktree is removed after the run. Every `review-*` alarm except
`review-stale` makes the cycle an alarm. A dry run makes no worktree, spawn,
kill, comment or stamp; the report's Review section says what would run and
what a finished run would post. `fleet launch <issue>` runs no review stage.

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
bin/fleet.js        CLI: cycle, launch, reap, status, resume, doctor, daemon, standards init, install
src/config.js       fleet.config.json, defaults, GH_BIN/GIT_BIN/CLAUDE_BIN seams
src/exec.js         argv-array process execution, detached spawn, liveness
src/scripts.js      runs sync-cells.sh and assign-cells.sh, parses their rows
src/tracker.js      every gh call the runtime makes
src/scope.js        SCOPE.json from the issue body; validation; slugs and paths
src/promote.js      pure promotion rule
src/launch.js       worktree + scope commit + plain push + detached claude -p
src/reap.js         liveness, timeout, pure classify()
src/verify.js       the verify stage: one verifier run in flight per target
src/review.js       the review stage: reviewers in fresh worktrees, REVIEWED stamps
src/merge.js        the merge stage: autoMerge PRs into the integration branch, never a protected one
src/store.js        atomic state file, cycle lock
src/report.js       report JSON, rendering, idempotent post
src/standards.js    drafts a target's .claude/standards.json from its clone
src/install.js      a target's worker files against the base ref: install branch, doctor drift
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
