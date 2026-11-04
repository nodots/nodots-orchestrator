# Agentic Work Packages: the Cell / Wave / Gate Model

**Status:** documented from practice, 2026-08-10; restructured 2026-09-06 so that no rule is stated twice
**Where the rules live:** the `agentic-work-packages` plugin skill in this repo, under `plugins/agentic-work-packages/skills/agentic-work-packages/`. That skill is the single source for every rule in this model. This document is the narrative around it: what the model is, what it replaced, and one complete worked example. Sections that used to restate a rule now point at the file that owns it — there is one copy to keep correct, not two.
**Canonical examples:** two programs in a private repo (one executed, 25+ cells; one planned to the same model). §9 is a fictional worked example, invented to the same shape, for readers without access.
**Lineage:** `nodots/auto-shop` (cells, SCOPE.json, phase gates) → `docs/autonomous-claude-system.md` + #15 (daemon-style orchestrator design, superseded) → the live pattern below (Claude coordinator + worktree-isolated subagents)

---

## 1. The model in one paragraph

A large program of work is decomposed into a **parent epic issue** that carries the execution plan, plus one **subissue per cell**. A *cell* is one work package: one bounded feature, one branch, one `SCOPE.json`, one worker agent, one `[READY]` PR. A **coordinator agent** (a Claude session run by the operator) dispatches cells in **waves** — batches of parallel workers whose dependencies are already merged — up to a WIP cap. Phases end in **validation gates** (V0, V1, …): blocking cells that prove the phase's cells integrate before the next phase's dependents dispatch. The coordinator never writes feature code; workers never touch the plan.

## 2. Anatomy of the parent epic

The epic's anatomy — its ten sections, in order, with the template — is
`plugins/agentic-work-packages/skills/agentic-work-packages/references/epic.md`.

## 3. Anatomy of a cell (the work package)

The cell's anatomy — sections, sizing rules, the `SCOPE.json` block and the
template — is
`plugins/agentic-work-packages/skills/agentic-work-packages/references/cell.md`,
with the field-by-field `SCOPE.json` reference, the `execution` profile and the
enforcement hook in `references/scope-contract.md`. A complete cell is at §9.2
below.

## 4. Dispatch rules (the coordinator's guidelines)

The dispatch rules — waves, the WIP cap, worktree isolation, coordinator and
worker roles, scope-down and escalation at dispatch, the coordination files, and
what to do when a cell uncovers unplanned work — are
`plugins/agentic-work-packages/skills/agentic-work-packages/references/coordination.md`.

## 4a. Execution profile defaults (the planner's mapping table)

The planner's mapping table from cell type to model tier and subagent pattern is
`references/coordination.md` §Execution profiles.

## 5. Label lifecycle

The label set and its lifecycle are `references/adapter-github.md` §Labels, with
`assets/scripts/bootstrap-github-labels.sh` to create them in a repo. Jira
statuses are in `references/adapter-jira.md`.

## 6. What changed from the original design

`docs/autonomous-claude-system.md` (and issue #15) designed a daemon: an issue-queue manager, spawn scripts, Redis, a monitoring dashboard. That machinery was **not** built. #360's execution decision reads: "running via Claude coordinator + worktree-isolated subagents (one `[READY]` PR per cell), **not** the auto-shop daemon. Lifecycle tracked by `cell:*` labels + these checkboxes." The GitHub issue tracker *is* the queue, dashboard, and audit log; the epic body *is* the orchestrator state. What survived from the daemon design: worktree isolation, the `claude-ready` label, branch-per-issue, quality gates before PR, the WIP cap idea.

## 7. Checklist: standing up a new epic

The procedure for standing up a new epic is the `agentic-work-packages`
`SKILL.md` §Procedure, with its pre-dispatch checklist.

## 7a. Drafting the plan with AI

The planner role and the three checks between a draft and a dispatch —
mechanical validation, adversarial plan review by a second agent, and the human
approval gate — are `references/epic.md` §Validating the plan.

## 8. Pointers

- The rules: the `agentic-work-packages` plugin skill in this repo —
  `SKILL.md`, then `references/` for the epic, cell, gate, `SCOPE.json`,
  coordination and adapter detail.
- Epic exemplars (private repo): #360 (executed — read its progress log for wave
  mechanics in practice), #406 (planned — cleanest current template).
- Cell exemplars (private repo): #367 (C1.2, cited as the cell template), #407
  (H0.1, latest refinement).
- Public exemplar: §9 below — fictional, complete, same shape as the private
  originals.
- Labels: `gh label list --repo <owner>/<host-repo>` (`cell:*`, `agent-ready`,
  `epic`).
- Pattern sources: `nodots/auto-shop`; `docs/autonomous-claude-system.md`
  (historical daemon design).
- Worker execution and evidence rules: [working-agreements.md](working-agreements.md).

## 9. Worked example (fictional)

Everything in this section is invented for illustration. The repo `example/acme-chess`, its issue numbers, and its cells do not exist; they mirror the structure of the private exemplars one-to-one. The program: adding online multiplayer to an existing single-player chess app.

### 9.1 The parent epic — `example/acme-chess#100`

Excerpted; the ten §2 sections appear in order. The workstreams section:

```markdown
## Workstreams & cells

**Phase 0 · Contract**
- [x] #101 · M0.1 Freeze the move-protocol package (types + wire format)
- [x] #102 · V0 gate — protocol round-trips: encode → send → decode → identical position

**Phase 1 · Server**
- [x] #103 · M1.1 Game session store (create/join/expire)
- [x] #104 · M1.2 WebSocket relay with reconnect
- [ ] #105 · M1.3 Server-side move validation against the frozen protocol
- [ ] #106 · V1 gate — two headless clients complete a full game over WS

**Phase 2 · Client**
- [ ] #107 · M2.1 Lobby UI (create/join)
- [ ] #108 · M2.2 Live board sync + opponent clock
- [ ] #109 · V2 gate — browser E2E: two real browsers, one game, held for human
```

Decisions log and progress log entries, showing the scope-down, gap-cell and escalation mechanics from `references/coordination.md`:

```markdown
## Decisions log
- 2026-08-03 — Protocol frozen at v0.1 after #101; all later cells carry
  `packages/move-protocol/**` in forbiddenPaths. Reversible only via a
  cell:contract-change cell.

## Progress log (live)
- **2026-08-04 · cycle 1 — moved.** Wave 1 dispatched: #103, #104
  (deps-free, cap 4, 2 used). Scope-down on #104 at dispatch: reconnect
  only; presence indicators deferred to a Phase 2 gap cell if needed.
- **2026-08-05 · cycle 2 — moved.** Wave 1 complete: #103, #104 merged.
  #104 revealed the session store has no expiry sweep — gap cell opened:
  #110 M1.1k, inserted before V1. Next wave: #105, #110.
- **2026-08-06 · cycle 3 — exhausted.** Open 5; blocked 1 (#110 on
  BLOCKER.md, kind human-decision, ref: product owner); in review 1
  (#105); free slots 3, nothing queued. No dispatch.
- **2026-08-07 · cycle 4 — moved.** #105 failed review twice (validation
  accepted illegal castling — deterministic red, classified, zero
  re-runs). Re-dispatched per the escalation rule: model one tier up,
  pattern solo → implement+review. Logged here; SCOPE.json default
  unchanged. #110 unblocked by the decision below.
```

### 9.2 A cell — `example/acme-chess#105`

```markdown
## Cell M1.3 — Validate moves server-side against the frozen protocol

**Part of** #100 · **Phase 1 · Server** · **Repo:** `example/acme-chess-server`

### Goal
The relay (#104) forwards any syntactically valid move; an illegal move
desyncs both clients. `relay.ts:88` forwards without consulting the
rules engine. Close that gap: every inbound move is validated before
broadcast, and an illegal move is rejected with a typed error — no
silent drop.

### Scope of work
- Add `validateMove(position, move)` call in `relay.ts` before broadcast
- Reject with `MoveRejected { reason, position }` over the wire — never
  disconnect, never silently drop
- Property test: generated random games, every broadcast move is legal

### SCOPE.json
{
  "feature": "server-move-validation",
  "project": "acme-chess",
  "branch": "feat/server-move-validation",
  "allowedPaths": ["src/relay/**", "src/validation/**", "test/**"],
  "forbiddenPaths": ["packages/move-protocol/**", "package.json", ".github/**"],
  "dependsOn": ["feat/websocket-relay"],
  "estimatedScope": "one session; ~3 files plus tests",
  "execution": {
    "model": "session default",
    "pattern": "solo",
    "window": "200k",
    "agents": []
  }
}

### Acceptance criteria
- [ ] Illegal move from a client produces MoveRejected, game state unchanged
- [ ] Property test passes: no illegal move is ever broadcast
- [ ] Every check in `.claude/standards.json` passes
- [ ] `[READY]:` PR opened, linked to this cell

### Dependencies
- **Depends on:** #104 · **Parallelizable:** yes — alongside #110.
```

### 9.3 The target repo's `CLAUDE.md`

Each target repo imports the worker contract from the hand-authored layer, so
every worker dispatched into it runs under the same reviewed file:

```markdown
# example/acme-chess-server

@.claude/worker-contract.md

## Domain invariants
- The move protocol package is frozen; changes go through a
  cell:contract-change cell.
```

The contract is installed as `.claude/worker-contract.md`, never as
`AGENTS.md`: tools that generate `AGENTS.md` whole would overwrite it.

### 9.4 A blocker — `BLOCKER.md` on the `feat/session-expiry` worktree

The gap cell #110 stopped on a decision it could not make inside its lane.

```markdown
# BLOCKER: M1.1k — expiry sweep needs a retention policy nobody has set

**Bucket:** blocked on a decision
**Kind:** human-decision
**Reference:** product owner
**Owner:** product owner
**Un-blocks when:** a retention value is recorded in the epic's decisions log

## What was needed, and why
The sweep must delete abandoned sessions. `store.ts:140` has no retention
value and none exists anywhere in the repo. Any number chosen here becomes
the product's data-retention behaviour by default.

## Alternatives searched
- Infer from the existing reconnect grace period (90s) — fails: that bounds
  one disconnect, not an abandoned game, and reusing it would expire live
  games mid-play.
- Ship the sweep behind a config flag defaulted off — fails: a flag nobody
  sets is a dead gate; the store still grows unbounded in production.
- Make it configurable with no default — fails: the deploy has no value to
  supply, so this is the same decision one layer further away.

## The ask
M1.1k: session retention before sweep — options: 24h / 7d / configurable
with a 7d default : recommendation 7d default, configurable : decide-by
the V1 gate : cost-of-waiting V1 cannot assert cleanup, and the store grows
unbounded on the staging stack.
```

Note the arc across the two excerpts: #105 was cut as `solo` on the default tier (the execution-profile table would have given a core-logic cell `implement+review`; the planner under-provisioned it), it failed review twice, and the escalation rule moved it up a tier at re-dispatch — with the escalation recorded in the progress log, not by editing the cell.
