# Developer guide: the orchestrator tools

A reference for working on, and with, the tools in this repository: the two
plugins, the repository scripts, the eval runner, the hooks and CI.

Nobody runs these tools by hand. You direct work at the level of the epic
("start work on epic #n"); a coordinator session and its worker sessions run
the tools, under the hooks and permissions in `.claude/`. The commands below
are what those sessions run, so you can read a transcript, answer a permission
prompt or check a claim against the output. For what you say to a coordinator
session at each stage of a program, see [cheat-sheet.md](cheat-sheet.md).

This guide describes tools, not rules. Where it touches a rule of the model
(lanes, stamps, blockers, handoffs), the plugin `references/` and the worker
contract govern, and this guide links to them rather than restating them.

## Contents

1. [Repository map](#1-repository-map)
2. [Prerequisites](#2-prerequisites)
3. [The test command](#3-the-test-command)
4. [Plugin: agentic-work-packages](#4-plugin-agentic-work-packages)
5. [Plugin: fleet](#5-plugin-fleet)
6. [Repository scripts](#6-repository-scripts)
7. [Evals](#7-evals)
8. [CI workflows](#8-ci-workflows)
9. [Writing a fixture test](#9-writing-a-fixture-test)
10. [Where things are written down](#10-where-things-are-written-down)

---

## 1. Repository map

| Path | What it is |
|---|---|
| `.claude-plugin/marketplace.json` | The `nodots-plugins` marketplace. This repo is the marketplace. |
| `plugins/agentic-work-packages/` | Plugin: skill, references, hooks, `cell-worker` agent, coordinator scripts, fixture tests. Version in `.claude-plugin/plugin.json`. |
| `plugins/fleet/` | Plugin: the coordinator runtime (`bin/fleet.js`, `src/`), its skill and fixture tests. |
| `scripts/` | Repository checks: `test.sh`, `check-syntax.sh`, `check-credentials.sh`, `check-stamp.js`, `metrics.js`, and their tests in `scripts/tests/`. |
| `evals/` | Non-interactive evals through `claude -p`: runner, cases, budget, gates. |
| `.claude/` | This repo's own installed worker hooks, worker contract and permissions. CI checks the hooks and contract match the plugin copies. |
| `.agentic/cells/<branch>/` | Per-package `SCOPE.json`, `HANDOFF.md`, `BLOCKER.md`. |
| `.github/workflows/` | `ci.yml`, `stamp-check.yml`, `evals.yml`. |
| `docs/` | Long-form docs. The plugin `references/` govern them. |
| `REVIEW.md` | How a PR in this repo is reviewed. |

## 2. Prerequisites

Installed on the machine where the Claude Code session runs.

| Tool | Needed for | Notes |
|---|---|---|
| `bash` | every script and fixture test | |
| `node` 20 | hooks, fleet, `metrics.js`, evals | builtins only; there is no `package.json` and nothing to install |
| `git` | fleet, credential check, tests | the fixture tests use a real `git` |
| `gh` | fleet, `sync-cells.sh`, `assign-cells.sh`, `metrics.js`, `aei-epic.js`, label bootstrap | authenticated to the host and target repos; not needed by any test |
| `claude` ≥ 2.1.259 | every session; fleet launches and evals also start `claude -p` sessions of their own | for `--permission-prompts`; not needed by any test |

The fixture tests stub `gh` and `claude`. Production code reads the binaries
through `GH_BIN`, `GIT_BIN` and `CLAUDE_BIN` (`plugins/fleet/src/config.js`),
which is the seam the tests use.

## 3. The test command

```bash
bash scripts/test.sh
```

One command, the same one CI runs. Workers run it before they stamp a PR. In
order:

1. Each `plugins/agentic-work-packages/hooks/*.js` is byte-identical to its copy
   in `skills/agentic-work-packages/assets/hooks/`.
2. Every `.js` and `.sh` under `plugins/` parses (`scripts/check-syntax.sh`;
   a parse check, not a linter).
3. No changed file holds a private-key header or token shape
   (`scripts/check-credentials.sh`, against `origin/development`).
4. Every `*.test.sh` under `plugins/agentic-work-packages/.../assets/tests/`,
   `plugins/fleet/tests/` and `scripts/tests/` passes.
5. Every `evals/tests/*.test.js` and `evals/gates/*.test.js` passes under `node`.
   None calls a model.

A glob that matches nothing is a failure. The run ends in `ALL PASS` or
`FAILED`, and exits non-zero on failure. A failing file prints its full output
indented under its `FAIL` line.

The full run takes over two minutes, longer than the session's default Bash
timeout of 120 seconds. The session has to pass a longer timeout or run it in
the background; a run cut off by the timeout is not a pass.

Environment:

| Variable | Effect |
|---|---|
| `REPO_ROOT` | run against another tree (used by `scripts/tests/test-sh.test.sh`) |
| `BASE_REF` | base for the credential check; default `origin/development`. An unresolvable ref fails the check. CI fetches full history for this. |

## 4. Plugin: agentic-work-packages

The planning model and its enforcement. Start at
`plugins/agentic-work-packages/skills/agentic-work-packages/SKILL.md`; it lists
every reference by topic.

### Hooks

Both wired automatically by `hooks/hooks.json` on plugin install. They fire on
the session's own tool calls and turn ends. Both fail open and print one stderr
line when they cannot evaluate.

| Hook | Event | Blocks |
|---|---|---|
| `enforce-scope.js` | `PreToolUse` on `Edit\|Write` | a write outside the branch's `SCOPE.json` lane (deny, never ask). No `SCOPE.json` means no restriction. Does not see shell writes, MCP or `NotebookEdit`. |
| `require-handoff.js` | `Stop` | ending a turn on a dirty non-default branch with neither `HANDOFF.md` nor `BLOCKER.md`, or with a `HANDOFF.md` lacking the `Plan check` section. |

Opt-in, not registered by the plugin: `require-handoff.js` as `TaskCompleted`,
`session-start-install-deps.sh` (`SessionStart`, remote sessions),
`enforce-scope-staged.js` (git pre-commit). Wiring is in
`assets/settings-snippet-optional.json`.

**Editing a hook:** the session changes `plugins/agentic-work-packages/hooks/<name>.js`,
copies it byte-for-byte to `skills/agentic-work-packages/assets/hooks/<name>.js`,
and, for the two installed in this repo, to `.claude/hooks/<name>.js`. `test.sh`
checks the first pair; `ci.yml` checks the `.claude/` copies. The `.claude/`
copy is live in the session making the edit, so a broken `enforce-scope.js` can
deny that session's next write.

### Coordinator scripts

In `skills/agentic-work-packages/assets/scripts/`, run by a coordinator session
directly or through `fleet cycle`. Every one is dry-run unless `--apply` is
passed, and every one that calls `gh` also takes `--state <file>`
so the same derivation runs over a fixture.

| Script | Does | Usage |
|---|---|---|
| `bootstrap-github-labels.sh` | creates or updates the label set, an optional program label, and `worker:<id>` labels | `bootstrap-github-labels.sh <owner>/<repo> [program-label] [worker-id...]` |
| `sync-cells.sh` | derives each package's `cell:*` label from merged PRs, current `VERIFIED` stamps, `BLOCKER.md` and branches | `sync-cells.sh --repo <host> [--target <repo>]... [--apply] [--emit-state <file>]` |
| `assign-cells.sh` | gives queued packages `worker:<id>` labels within the WIP cap and contract-change holds | `assign-cells.sh --repo <host> --workers a,b [--wip-cap N] [--apply]` |
| `aei-epic.js` | enumerates the epic checklist as AEI v1 JSON for an external stop guard; fails closed | `aei-epic.js --repo <owner>/<repo> --epic <n>` or `--epic-file <path>` |
| `stamp.js` | module: the one definition of a `VERIFIED` stamp and of "current" | required by `sync-cells.sh`, `check-stamp.js`, `metrics.js` |

`sync-cells.sh` precedence, first match wins: PR merged → `cell:merged`; PR open
with a current stamp → `cell:awaiting-review`; `BLOCKER.md` on the branch →
`cell:blocked`; branch, no PR → `cell:active`; otherwise unchanged.

Exit codes shared by the scripts: `0` ok, `1` a label write failed, `64` usage,
`66` no such `--state` file, `69` missing binary, `70` internal, `75` the
tracker listing was truncated.

### Worker contract and agent

- `assets/worker-contract.md` — what every worker runs under. Installed in a
  target repo as `.claude/worker-contract.md` and imported from its `CLAUDE.md`.
  This repo has its own installed copy; CI checks it matches.
- `agents/cell-worker.md` — the agent that runs one package.

### Tests

`skills/agentic-work-packages/assets/tests/*.test.sh`: one per hook and script,
plus `harness.test.sh` and `v4-gate.test.sh`.

## 5. Plugin: fleet

The coordinator runtime. One `fleet cycle --apply` is one pass:

```
lock → sync-cells.sh --apply → promote → assign-cells.sh --apply → launch → reap → report → unlock
```

No daemon. A coordinator session runs cycles, on an interval with `/loop`, and
reads each report; each launch starts a detached `claude -p` worker session.
State is the tracker plus `<stateDir>/state.json`. The `fleet` skill
(`plugins/fleet/skills/fleet/SKILL.md`) is what the coordinator session follows,
including what each alarm asks of it; the mechanics are in
`plugins/fleet/README.md`.

### Locating the CLI

The `fleet` skill resolves the path. For reference:

```bash
# from a checkout of this repo
FLEET=plugins/fleet/bin/fleet.js
# the installed copy
FLEET=$(ls -d ~/.claude/plugins/cache/*/fleet/*/bin/fleet.js | sort -V | tail -1)
```

`$CLAUDE_PLUGIN_ROOT` is set only inside a plugin's own hooks, not in a
coordinator session.

### Commands

| Command | Writes | Purpose |
|---|---|---|
| `cycle [--apply] [--json]` | with `--apply`: labels, worktrees, pushes, sessions, one epic comment, state | one pass; dry run without `--apply` |
| `launch <issue> [--apply]` | as `cycle`, narrowed to one issue | dispatch one package now, through the cycle's own path |
| `reap [--apply] [--json]` | with `--apply`: state | classify finished sessions only |
| `status [--json]` | nothing | local state, streak, latch, sessions |
| `resume --reason <text>` | state | clear the stop latch; the reason is recorded |
| `doctor` | nothing | binaries, plugin scripts, worker contract, hooks and workspace trust in each target, labels, epic |

All take `--config <file>`; otherwise `FLEET_CONFIG`, otherwise
`./fleet.config.json`.

Exit codes: `0` ok · `1` a label write failed · `64` usage · `69` missing
binary · `70` internal · `75` collection truncated · `78` latched · `79` another
cycle holds the lock.

### Configuration

Copy `plugins/fleet/fleet.config.example.json`. Relative paths resolve against
the config file's directory. Validation is in `src/config.js`.

| Key | Default | Meaning |
|---|---|---|
| `repo` | required | host repo holding the issue graph, `owner/name` |
| `epic` | required | epic issue number |
| `targets` | required | `[{ repo, localPath, defaultBranch }]`; `defaultBranch` defaults to `main` |
| `workers` | required | `{ <id>: { mode } }`, mode `local`, `cloud` (not implemented) or `external` (labeled and observed only) |
| `wipCap` | 4 | packages in flight across all workers |
| `worktreesDir` | `<first target's parent>/<name>-worktrees` | where worker worktrees go |
| `stateDir` | `<worktreesDir>/.fleet` | `state.json`, `cycle.lock`, `logs/` |
| `pluginRoot` | sibling or highest installed `agentic-work-packages` | where the coordinator scripts and contract are read from |
| `permissionMode` | `acceptEdits` | worker `--permission-mode` |
| `permissionPrompts` | `none` | `none` or `host` |
| `maxBudgetUsd` | 25 | worker `--max-budget-usd` per session |
| `sessionTimeoutMinutes` | 120 | wall clock, then SIGTERM, then SIGKILL after `killGraceSeconds` (60) |
| `maxEscalations` | 2 | failed attempts before an `escalation-cap` alarm |
| `noMovementLimit` | 3 | cycles without movement before the latch |
| `maxCycleMinutes` | 30 | stale-lock threshold |
| `externalStartTimeoutMinutes` | 240 | how long an `external` worker has to start |
| `ciMaxAgeDays` | 14 | a target with no default-branch CI run inside this window is not launched onto |
| `approvalEnforcement` | `off` | `off`, `branch-protection` or `ruleset`; see `plugins/fleet/README.md` §Approval enforcement |
| `models` | `{ cheapest: haiku, default: null, strongest: opus }` | tier to model; `null` means the session default |
| `bins` | `gh`, `git`, `claude` | overridden by `GH_BIN`, `GIT_BIN`, `CLAUDE_BIN` |

### Source layout

| File | Responsibility |
|---|---|
| `bin/fleet.js` | CLI parsing and the six commands |
| `src/config.js` | load, validate, defaults; `approvalPayload`, `approvalGate` |
| `src/cycle.js` | the pass; `EXIT` codes |
| `src/scripts.js` | runs `sync-cells.sh` and `assign-cells.sh` |
| `src/tracker.js` | every `gh` call |
| `src/scope.js` | `SCOPE.json` from the issue body; validation |
| `src/promote.js` | pure promotion rule |
| `src/launch.js` | worktree, scope commit, plain push, detached `claude -p` |
| `src/reap.js` | liveness, timeout, `classify()` |
| `src/store.js` | atomic state file, cycle lock |
| `src/report.js` | report JSON, render, idempotent post |
| `src/exec.js` | argv-array process execution, detached spawn |
| `src/trust.js` | workspace-trust check for `doctor` |

Worker logs: `<stateDir>/logs/<issue>-<attempt>.log`, the
`claude -p --output-format json` result.

### Tests

`plugins/fleet/tests/*.test.sh`. `cycle.test.sh` runs a whole pass against a
bare git remote, the real plugin scripts, a stateful `gh` stub
(`tests/stubs/gh.js`) and a scripted `claude` stub (`tests/stubs/claude.sh`).

## 6. Repository scripts

| Script | Does | Exit |
|---|---|---|
| `scripts/test.sh` | the one test command (§3) | 0 all pass, 1 otherwise |
| `scripts/check-syntax.sh` | `node --check` every `.js`, `bash -n` every `.sh` under `plugins/` | non-zero on a parse error or no files |
| `scripts/check-credentials.sh` | pattern match for key headers and token prefixes in changed, staged, unstaged and untracked files; names the file, never the match | non-zero on a hit or unresolvable base |
| `scripts/check-stamp.js <pr.json>` | a `[READY]:` PR must carry `VERIFIED: <suite> @ <head sha>`; input `{ title, headSha, comments }` | 0 pass or not READY, 1 otherwise |
| `scripts/metrics.js --repo <owner/name> [--last N] [--state-dir <dir>] [--pr-limit N] [--json]` | delivery metrics for the last N merged packages; each value labeled measured, estimated or unknown; cost from fleet logs | 0 report, 1 gh unreadable, 2 usage |

## 7. Evals

```bash
node evals/run.js [--cases evals/cases] [--budget evals/budget.json] [--results out.json] \
                  [--workdir <dir>] [--claude claude] [--month-spent USD] [--contract <file>]
```

A session runs these on request. They call a real model and spend money. The caps in `evals/budget.json` are
estimates. Each case runs in a fresh temp directory unless `--workdir` is
given. Full description: `evals/README.md`.

| Path | Contents |
|---|---|
| `evals/cases/*.json` | one case per file; format `evals/schema.json`, example `_example.json`. Naming: `trigger-*` (skill triggering), `contract-*` (worker contract), `incident-pr<N>-*` (a failure found in practice) |
| `evals/budget.json` | `perEvalUsd`, `perSuiteUsd`, `monthlyCeilingUsd`, `model`, `timeoutSeconds` |
| `evals/baseline.json` | the pass-rate bar the CI gate uses |
| `evals/spend.json` | measured spend per run, a committed record |
| `evals/gates/` | gate runs and their records |
| `evals/tests/` | runner tests against `tests/stubs/claude.sh`; no model calls |

Exit codes: `0` all passed, `1` an eval failed or did not run, `2` bad input.

## 8. CI workflows

| Workflow | Trigger | Runs |
|---|---|---|
| `ci.yml` | push to `development`, every PR | `bash scripts/test.sh`; then the `.claude/hooks/*.js` and `.claude/worker-contract.md` match the plugin copies |
| `stamp-check.yml` | PR opened/synchronized/edited, PR comment created/edited/deleted | `scripts/check-stamp.js` on the PR |
| `evals.yml` | manual (`workflow_dispatch`) only | the evals, gated on `evals/baseline.json` and the monthly ceiling; needs `ANTHROPIC_API_KEY` |

## 9. Writing a fixture test

Fixture tests are bash plus Node builtins, with `gh` and `claude` stubbed and
`git` real.

```bash
#!/usr/bin/env bash
# Fixture test for <thing>: <the behavior it pins>.
set -uo pipefail
cd "$(dirname "$0")"
. ./lib.sh

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

out=$(bash ../path/to/script.sh --state "$TMP/state.json" 2>&1)
assert_contains "$out" "expected row" "script reports the expected row"

finish
```

- Name it `*.test.sh` and put it in one of the three test directories; `test.sh`
  picks it up by glob.
- `lib.sh` lives in `$ASSETS/tests/` and `plugins/fleet/tests/`; tests in
  `scripts/tests/` source `../../plugins/fleet/tests/lib.sh`. It provides `assert_eq`, `assert_ne`, `assert_contains`,
  `assert_not_contains`, `assert_nonempty`, `assert_empty`, `assert_file`, and
  `finish`, which prints `--- N checks, M failed` (the tally `test.sh` reports)
  and sets the exit status.
- A node test under `evals/` prints the same `--- N checks, M failed` line and
  sets `process.exitCode = 1` on failure.
- The session writes the test first and shows it failing against the unchanged
  tree before making the change.

## 10. Where things are written down

| What | Where |
|---|---|
| Intent (context, success criteria, out of scope) | the epic issue |
| Spec and plan for a package (goal, scope, `SCOPE.json`, acceptance criteria, dependencies) | the package issue |
| A package's lane | `.agentic/cells/<branch>/SCOPE.json`, copied verbatim from the issue |
| Resume state, blockers | `.agentic/cells/<branch>/HANDOFF.md`, `BLOCKER.md` |
| Rules of the model | the plugin `references/` and `assets/worker-contract.md` |
| Review procedure | `REVIEW.md` |

The tracker issue is the single source of truth. No `intent.md` or `spec.md` is
kept in git; a change of scope is an edit to the package issue.
