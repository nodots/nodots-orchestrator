---
name: agentic-work-packages
description: Decompose work into a hierarchy of tracker issues that autonomous coding agents can execute in parallel — epics, path-scoped work packages, and blocking verification gates. Use when planning a multi-week feature, breaking an epic into agent-executable tasks, setting up parallel agent workstreams, writing issues or tickets intended for autonomous agents rather than people, or producing a delivery plan an agent fleet can run unattended. Tracker-neutral, with GitHub Issues and Jira adapters.
---

# Agentic work packages

Turn a body of work into an issue hierarchy that autonomous agents execute in
parallel, without a human deciding each step, and without agents colliding.

This skill is normative. It describes a model proven on a multi-phase program
(≈30 packages, five phases, four concurrent agents). Where a default habit
conflicts with it — writing a task list, sizing by story points, letting one
agent range across a repo — this skill governs.

## When this applies

Use it when **all three** hold:

- the work splits into three or more units;
- at least two units could run at the same time;
- agents, not people, will do the implementing.

Do not use it for a single bug fix, for exploratory research, or for work whose
scope cannot yet be pinned to file paths. If scope cannot be pinned, the
prerequisite is exploration, not decomposition.

## The model

| Tier | What it is | Executed by |
|---|---|---|
| **Program doc** | Design rationale, research, alternatives. Optional. | nobody — it is input |
| **Epic** | The execution plan: context, phases, success criteria, out of scope, logs | coordinator |
| **Package** | One bounded change: one branch, one `SCOPE.json`, one agent, one PR | one worker agent |
| **Gate** | Blocking proof that a phase's packages actually work together | one worker agent, or a human |

"Package" is the unit that matters. Some teams call it a cell. It is the
smallest thing an agent can finish in one sitting and prove with tests.

### Seven invariants

These are what make unattended parallel execution safe. Breaking any one of them
is how the model fails.

1. **One package = one bounded change = one branch = one `SCOPE.json` = one
   agent = one PR.** Two repos means two packages.
2. **Scope is declared as paths and enforced mechanically**, not by asking the
   agent to be careful. See `references/scope-contract.md`.
3. **Dependencies are declared three times and must agree**: in the issue's
   `Depends on` line, in `SCOPE.json.dependsOn`, and in the phase ordering.
4. **Every phase ends in a blocking gate**, and a gate may not edit what it
   verifies — its `allowedPaths` are tests only.
5. **Discovered work becomes a new package.** Never widen a live lane.
6. **Decision and progress logs are append-only.** They are the only memory that
   survives between waves of agents.
7. **Done is proved, not asserted.** The failing test is written before the
   change; a package that adds a field, type or dependency names its boundary
   round-trip test; a suite that never executes is not a gate. See
   `references/working-agreements.md` — green tests are necessary and not
   sufficient, and most shipped defects came from packages whose tests could not
   fail.

## Procedure

**1. Explore first.** You cannot write a dispatchable package from a feature
description. Read the code until you can name each gap with file paths and line
ranges. An epic whose context section says "the API needs auth" produces
packages that fail; one that says "only the DELETE routes use `authMiddleware`;
roll, move, confirm-turn and resign never read `req.user` (`src/routes/x.ts:192-300`)"
produces packages that succeed. Budget most of the planning effort here.

**2. Pick a program letter and phases.** Each program takes an unused letter
(`A`, `H`, `P`…). Packages are `<letter><phase>.<n>` — `H0.1`, `H2.3`. Gates are
`V<phase>`. Phases are ordered by what must be proven before the next thing can
be built on it, not by team or by layer.

**3. Write the epic** — `references/epic.md`.

**4. Write the packages** — `references/cell.md`. Size: if acceptance criteria
exceed about six checkboxes, or `allowedPaths` spans two subsystems, split it.

**5. Write the gates** — `references/gate.md`.

**6. File them** — `references/adapter-github.md` or `references/adapter-jira.md`
for the tracker mechanics: parentage, labels or statuses, and the create calls.

**7. Install enforcement** in every target repo. Two hooks, both wired
automatically by the plugin; for a manual install, copy
`assets/hooks/enforce-scope.js` and `assets/hooks/require-handoff.js` to
`.claude/hooks/` and merge `assets/settings-snippet.json` into
`.claude/settings.json`.

- `enforce-scope.js` (`PreToolUse`) blocks an `Edit`/`Write` outside the
  package's lane. Without it, `SCOPE.json` is a suggestion.
- `require-handoff.js` (`Stop`) blocks a turn from ending on a dirty feature
  branch with neither `HANDOFF.md` nor `BLOCKER.md` written. Without it, a
  compacted worker's state is gone.

Three more are opt-in, because the plugin cannot safely register them for every
repository: the same handoff check as a `TaskCompleted` hook,
`session-start-install-deps.sh` for remote sessions (`references/remote-execution.md`),
and `enforce-scope-staged.js` as a git pre-commit check. Wire the first two from
`assets/settings-snippet-optional.json`.

Install the worker contract in the same pass: copy `assets/worker-contract.md`
to `.claude/worker-contract.md` and import it with `@.claude/worker-contract.md`
from the hand-authored part of the repo's `CLAUDE.md`. It is not shipped as
`AGENTS.md` on purpose — see `references/coordination.md` §The worker contract.

Install the standards manifest in the same pass: `.claude/standards.json`, next
to the contract, generated with `fleet standards init` or written by hand, and
checked with `assets/scripts/check-standards.js`. It names the repo's checks and
rule documents; the plugin ships no standards (`references/standards.md`). The
preamble hook, `assets/hooks/standards-preamble.js` (`SessionStart`), ships with
the other two and prints the preamble the manifest names.

**7a. Brief workers on the working agreements** — `references/working-agreements.md`:
test-first, dead gates, no silent fallbacks, boundary round-trip tests, release
sequencing, destructive-command safety, reporting. Package acceptance criteria
should name the failing test, and UI packages the browser E2E.

**8. Dispatch and coordinate** — `references/coordination.md`: waves, the WIP
cap, worktrees, `BLOCKER.md` / `HANDOFF.md`, and what to do when a package
uncovers work nobody planned. `references/cheat-sheet.md` maps what the operator
says at each stage to what the coordinator does; when the operator asks what
they can say next, answer from it. When the workers run on other Claude accounts
than the coordinator, add `references/multi-account.md`: the tracker is the bus,
and `worker:<id>` labels say who owns what.

For the recurring work around dispatch, use `references/coordinator-checklists.md`
and `references/merge-procedure.md`. A change to a frozen shared interface follows
`references/contract-change.md`, a feature spanning repositories follows
`references/cross-repo.md`, and a worker on a hosted VM follows
`references/remote-execution.md`. Design each lane with `references/scope-design.md`
before filing the package.

## Numbering rules

- Never renumber. Branch names, `dependsOn` entries and cross-references outlive
  any tidying instinct.
- Work discovered mid-run keeps its phase and takes a letter suffix: `C2.6b`,
  `C2.0k`. It is filed where it belongs in the dependency order, not appended at
  the end.
- The package ID goes in the issue title, in the branch name, and in the PR
  title. It must be greppable across all three.

## Pre-dispatch checklist

- [ ] Epic exists, with context naming real gaps at file level
- [ ] Out of scope written, with links to whatever inherits the excluded work
- [ ] Every phase ends in a gate
- [ ] Every package: parent link, target repo, goal, file-level scope,
      `SCOPE.json`, acceptance criteria, dependencies
- [ ] `dependsOn` (branches) agrees with `Depends on` (issues) agrees with phase
      order
- [ ] Contract, migration, dependency and CI paths are in every package's
      `forbiddenPaths` except the one package that owns them
- [ ] Packages with no unmet dependencies are marked ready and queued
- [ ] Packages needing human judgement are **not** marked agent-ready
- [ ] Every target repo carries both hooks — scope and handoff — and the worker
      contract, and a `.claude/standards.json` that `check-standards.js` accepts

## Files

| Path | Contents |
|---|---|
| `references/epic.md` | Epic anatomy and template |
| `references/cell.md` | Package anatomy and template |
| `references/gate.md` | Gate anatomy and template |
| `references/scope-contract.md` | `SCOPE.json` spec, enforcement, worker protocol |
| `references/coordination.md` | Dispatch, waves, logs, anti-patterns |
| `references/multi-account.md` | One account coordinates, others implement: `worker:<id>` labels, assignment, reassignment |
| `references/scope-design.md` | Designing `allowedPaths` and `forbiddenPaths`: heuristics, worked path sets, failure patterns |
| `references/coordinator-checklists.md` | The coordinator's recurring checklists: opening a wave, reviewing blocked work, release order |
| `references/merge-procedure.md` | Pre-merge checklist and merge sequence, per branch flow |
| `references/contract-change.md` | Changing a frozen shared interface: request, review, rebase, merge |
| `references/cross-repo.md` | A feature that spans repositories: ordering, migrations, PR template, merge chain |
| `references/remote-execution.md` | Running a worker on a hosted VM with `claude --remote` |
| `references/context-management.md` | What belongs in a file rather than in a session's context |
| `references/agent-teams.md` | Running a package with an agent team inside one lane |
| `references/working-agreements.md` | Proof of done: test-first, dead gates, boundaries, release order, reporting |
| `references/cheat-sheet.md` | The operator's side: what to say to a coordinator session at each stage, and what it does in response |
| `references/standards.md` | The `.claude/standards.json` manifest: a repo's checks, rule documents and preamble |
| `references/adapter-github.md` | GitHub Issues mechanics |
| `references/adapter-jira.md` | Jira mechanics |
| `assets/hooks/enforce-scope.js` | PreToolUse scope hook, no dependencies |
| `assets/hooks/require-handoff.js` | Stop hook: no exit from a dirty lane without written state; also runs as an opt-in `TaskCompleted` hook |
| `assets/hooks/enforce-scope-staged.js` | Opt-in git pre-commit check: staged files against the lane, so it also catches shell-mediated writes |
| `assets/hooks/session-start-install-deps.sh` | Opt-in `SessionStart` hook for remote sessions: installs dependencies and flags a wrong-repository checkout |
| `assets/hooks/standards-preamble.js` | `SessionStart` hook: prints the preamble the repo's manifest names, and nothing in a repo without one |
| `assets/standards.schema.json` | JSON Schema for `.claude/standards.json` |
| `assets/scripts/check-standards.js` | Validates a repo's `.claude/standards.json` against the schema |
| `assets/settings-snippet-optional.json` | Wiring for the opt-in `TaskCompleted` and `SessionStart` hooks |
| `assets/github-issue-templates/` | GitHub issue templates: work package, blocker, contract change |
| `assets/retrospective-template.md` | Template for a per-program retrospective |
| `../../agents/cell-worker.md` | The `cell-worker` agent: runs one package under the worker contract |
| `assets/worker-contract.md` | The checked-in worker contract; install as `.claude/worker-contract.md` |
| `assets/settings-snippet.json` | Hook wiring for `.claude/settings.json` |
| `assets/tests/` | Fixture tests for the hooks and scripts; run in CI |
| `assets/scripts/bootstrap-github-labels.sh` | Creates the label set in a repo |
| `assets/scripts/sync-cells.sh` | Derives `cell:*` labels from observable state |
| `assets/scripts/assign-cells.sh` | Coordinator: assigns queued packages to worker accounts as `worker:<id>` labels |
| `assets/scripts/aei-epic.js` | Optional: enumerates the epic backlog for a runtime stop guard |
