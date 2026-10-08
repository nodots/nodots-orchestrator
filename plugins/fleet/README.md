# fleet

Coordinator runtime for the `agentic-work-packages` plugin. One command, one
pass:

```
fleet cycle --apply
  lock → sync-cells.sh --apply → promote → assign-cells.sh --apply → launch → reap → report → unlock
```

- **sync** derives every `cell:*` label from branches, PRs and `BLOCKER.md`
  (the plugin's script; fleet reads its state through `--emit-state`).
- **promote** adds `cell:queued` to an `agent-ready` package once every
  `dependsOn` branch has a merged PR.
- **assign** hands queued packages to worker ids as `worker:<id>` labels, within
  the WIP cap and the contract-change holds (the plugin's script).
- **launch**, for each queued package owned by a local worker id: a git
  worktree on the package branch, the issue's `SCOPE.json` committed as
  `<ID>: scope`, a plain push as the claim, then a detached
  `claude -p … --permission-prompts none --max-budget-usd …` in the worktree.
- **reap** classifies finished sessions: PR ⇒ movement; `BLOCKER.md` with a
  known Kind ⇒ parked for the coordinator; silent or failed ⇒ escalate one
  model tier up, up to `maxEscalations`.
- **report** posts one Movement / Exhaustion / Alarm comment on the epic, with
  a marker so a re-post is a no-op, and keeps the no-movement streak that
  latches the fleet after `noMovementLimit` cycles.

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
