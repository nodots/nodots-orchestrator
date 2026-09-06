# Implementation plan: HARNESS_CROSS_EVALUATION.md

**Status:** draft, 2026-09-06; revised the same day after the two nodots repos were consolidated
into this one. Derived from `HARNESS_CROSS_EVALUATION.md` (the evaluation), which is gitignored
here because it derives from a client engagement.
**Executes:** N-1 to N-16. The H- items are not executed here; section 8 records the handoff.

The evaluation names two repos. Both now live in `nodots/nodots-orchestrator` (private, default
branch `development`) with history preserved:

| evaluation's name | now at | imported from |
|---|---|---|
| A: plugin (`agentic-work-packages`) | `plugins/agentic-work-packages/` | `development` @ `b6b1e6b` |
| B: public doc (`nodots-ai-workflows`) | `docs/` | `docs/working-agreements` @ `8cbbcd4` |

Paths below are written relative to those two directories; `references/` means
`plugins/agentic-work-packages/skills/agentic-work-packages/references/`. The repo has no CI, no
`scripts/` directory, no `package.json`, and no test. Three evaluation items require CI (N-1, N-5,
N-10), so phase 0 creates it.

---

## 1. Ground rules carried over from the evaluation

1. Feature branches off `development` only, never a commit on `development` itself. The
   evaluation says "one PR per repo"; with one repo this plan reads that as one PR per phase so
   a reviewer never sees more than about five items in one diff.
2. Nothing from the client engagement enters either repo: no person names, no product or
   subsystem names, no board item ids, no stack ids. The N- items are already clean. Every PR
   description gets a line stating this check was done.
3. Nothing is quoted from AIQT Guardrails (CC BY-SA 4.0). Where an item needs AIQT's
   protocol shape (N-14, N-16), read it from a clone pinned at `52e69c6` and restate in nodots
   terms.
4. Tests are bash fixture scripts and Node builtins, no npm dependencies, matching the plugin's
   current zero-dependency posture. Every hook or script ships with its fixture test in the
   same PR.
5. The two copies of `enforce-scope.js` stay byte-identical; CI asserts it.
6. Each phase ends with the evaluation's own acceptance check run and its output pasted into
   the PR. The `Status` field in `HARNESS_CROSS_EVALUATION.md` is updated with the PR link when
   the PR merges (section 7).

---

## 2. Dependency graph

Stated in the evaluation:

- N-15 depends on N-1.
- N-14 depends on N-8.
- N-16 depends on N-13.
- N-6's plugin-side target (`references/cell.md`) exists only after N-10 ports the `execution` block.

Found while grounding:

- N-3 (`sync-cells.sh`) parses the stamp literal N-2 defines, so N-2 lands first or in the same PR.
- N-5's third legal outcome cites N-14, so the N-5 decision (section 6) is made before phase 4.
- N-10's mirror check is now an in-repo script over `docs/` and `references/`. It is only useful
  over final text, so it is scaffolded in phase 2 and turned on in CI in phase 6.
- N-16 overrides N-13's filename: the worker contract must not ship as `AGENTS.md`. N-13 is
  executed with that constraint from the start rather than renamed later.
- All doc edits (N-4, N-6, N-7, N-8, N-9, N-11) touch sections that N-10 restructures, so N-10
  goes before them.

Order: 0 → 1 → 2 → 3 → 4 → 5 → 6. Phases 3, 4 and 5 are independent of each other once phase 2
is merged and can run in parallel on separate branches.

---

## 3. Phase 0: pre-flight (S)

No evaluation item; prerequisites for everything after.

1. **CI skeleton.** `.github/workflows/ci.yml`: ubuntu, Node 20, runs
   `bash plugins/agentic-work-packages/skills/agentic-work-packages/assets/tests/*.test.sh` and
   `diff plugins/agentic-work-packages/hooks/enforce-scope.js plugins/agentic-work-packages/skills/agentic-work-packages/assets/hooks/enforce-scope.js`.
   No `continue-on-error`. Ship with a trivial passing test so the workflow is proven green
   before any real test depends on it (working-agreements §3: a gate that has never run is not
   a gate).
2. **AIQT reference clone** into the scratchpad at `52e69c6`, read-only, for N-14 and N-16.
   Nothing is copied out of it.
3. **Branch protection** on `development` requiring the CI check. Verify with
   `gh api repos/nodots/nodots-orchestrator/branches/development/protection`.

The evaluation's concern about the public repo's unmerged `docs/working-agreements` branch is
settled: `docs/` was imported from that branch, so `docs/working-agreements.md` exists on
`development`.

Acceptance: a green CI run on the pre-flight PR.

---

## 4. Phase 1: scope hook correctness (N-1, N-12, N-15)

One PR. Plugin version 1.1.0 → 1.1.1. Highest value per hour in the whole
plan: every plugin-install user currently has no scope enforcement.

### N-1. Fix root resolution and prove it

- Files: `hooks/enforce-scope.js`, `skills/agentic-work-packages/assets/hooks/enforce-scope.js`
  (identical), new `skills/agentic-work-packages/assets/tests/enforce-scope.test.sh`,
  `.claude-plugin/plugin.json`.
- Change at `enforce-scope.js:101`: read `event.cwd`; when present, root is
  `git -C "<cwd>" rev-parse --show-toplevel`; when absent, keep `path.resolve(__dirname, '..', '..')`.
  In a linked worktree `--show-toplevel` returns the worktree root, which is where that
  worker's `SCOPE.json` lives, so worktree isolation is preserved.
- Test: create a temp repo, `git init -b feat/thing`, one commit, root `SCOPE.json` with
  `allowedPaths: ["src/**"]`, `forbiddenPaths: ["package.json"]`. Simulate both installs by
  copying the hook to `<repo>/.claude/hooks/` and to `<tmp>/fake-plugin/hooks/`. Run each copy
  from a directory outside the repo with stdin JSON carrying `cwd` = the repo. Assert the seven
  rows of the evaluation's table, plus one row with `cwd` absent to prove the fallback.
- Acceptance: plugin-install rows read 2 / 0 / 2; test green in CI.

### N-12. Hook hygiene rules

- File: `references/scope-contract.md` §Enforcement (currently lines 55-88).
- Add the three rules: never land in a permission prompt (allow-by-rule or deny-with-reason);
  a deny message never instructs a manual edit of hook-owned state; success silent, failure
  verbose.
- Code: the `catch` at `enforce-scope.js:125` writes one stderr line naming the hook and the
  error before `exit(0)`. Exit code unchanged. Test row: malformed `SCOPE.json` → exit 0 and
  non-empty stderr.

### N-15. Deny, never ask, with a control header

- Files: both hook copies (header comment), `references/scope-contract.md` §Enforcement,
  `references/adapter-github.md`.
- Header gains three labelled lines: `Default: deny`, `Fail posture: open` with the reason,
  `Residue:` Bash-mediated writes, `sed -i`, shell redirects, MCP filesystem tools,
  `NotebookEdit` and `MultiEdit` (the matcher is `Edit|Write` only). State the deny-never-ask
  reason in the doc in nodots' words.
- Test: the out-of-lane row asserts exit 2 and no permission-ask JSON on stdout.

Acceptance for the phase: the fixture test passes from both install locations; the header
carries the three fields; CI green.

---

## 5. Phase 2: one source per rule (N-10)

One PR. Plugin version bump deferred to phase 4 (docs only here).

### Plugin side: port what only the long-form doc has

| public doc section | lands in |
|---|---|
| `execution` block (model, pattern, agents) | `references/cell.md` template and `references/scope-contract.md` §Fields |
| §4a mapping table | `references/coordination.md`, new §Execution profiles |
| rule 10 (escalate one tier or add a reviewer after two failures, logged) | `references/coordination.md` §The coordinator |
| §7a planner protocol (mechanical validation, adversarial plan review, human approval gate) | `references/epic.md`, new §Validating the plan |

Then: `SKILL.md:40` "Six invariants" → "Seven invariants" (seven are listed; do not drop #7).

### Both sides: settle `dependsOn` as branch names

The plugin already says branch names (`scope-contract.md:30`). The long-form doc says feature
names at `docs/agentic-work-packages.md:54` and its worked example at line 250 uses
`"websocket-relay"`. Fix both to branch form and make the worked example's branch name
consistent with its own §9 cell.

### Mirror check

Consolidation removed the cross-repo problem but not the duplication: `docs/` and `references/`
still state the same rules twice. Two options, decide at phase start:

- **Delete the duplicate (recommended).** Cut the mirrored sections from
  `docs/agentic-work-packages.md` and replace each with a one-line pointer to the plugin
  reference file. The doc keeps what only it has: the narrative, §6 history, and the §9 worked
  example. No script, nothing to drift.
- **Keep both and check.** Mark each mirrored section with HTML comment fences
  (`<!-- mirror:begin <name> -->` / `<!-- mirror:end <name> -->`); new `scripts/check-mirror.sh`
  extracts fenced sections from `docs/` and `references/` and diffs them, exit 1 on any
  difference. Wire it in phase 6, not here, so phases 3 to 5 do not fight the check.

Acceptance: no rule stated in both places with different wording (by inspection under the first
option, by `check-mirror.sh` exit 0 under the second);
`grep -c '^[0-9]\.' SKILL.md` under the invariants heading matches the heading's number.

---

## 6. Phase 3: coordinator and worker rules (N-4, N-6, N-7, N-8, N-9, N-11)

All S. One PR. Doc-only, no version bump. Every item lands on both sides where the evaluation
names both, unless phase 2 deleted the duplicate, in which case it lands in `references/` only.

| item | plugin files (`references/`) | `docs/` files | what lands |
|---|---|---|---|
| N-4 | `coordination.md` §The coordinator; `epic.md` progress-log entry format | `agentic-work-packages.md` §4 | cycle contract (three legal answers), post-compaction reconcile, stop after 3 no-movement cycles |
| N-6 | `cell.md` execution block (from phase 2) | §4a table, §3 | "output verifiable by a tool?" column as the deciding criterion; `window`/`autocompact` field or the warning; cost per unit of delivered work, never per day |
| N-7 | `working-agreements.md` | `working-agreements.md` §2a, §8a | shape rule (deterministic red: zero re-runs; infrastructure red: one), witness never authors the green, four hypotheses at a product boundary |
| N-8 | `coordination.md` `BLOCKER.md` template; `scope-contract.md` §Worker protocol | `working-agreements.md` §8a | required fields: bucket, kind (`tracked-task`, `human-decision`, `external`, `foreign-lease`, `not-before`) plus reference, alternatives searched, un-block condition, owner, one-line ask; parked-with-skip rule; "stopped looking" fails review |
| N-9 | `coordination.md` §Isolation | §4 rule 3 | `git worktree list` before editing; detached worktree plus `--force-with-lease=<branch>:<known-head>` for follow-ups; two-dot diff and `git merge-tree` before merge |
| N-11 | `cell.md`, `gate.md` templates | §3 pattern vocabulary | optional verifier restatement of acceptance criteria before the worker builds; disagreement is a package defect filed before code |

`coordination.md` currently has no `BLOCKER.md` template (it has a three-row table at
§Coordination files); N-8 adds one. The worked example in `docs/agentic-work-packages.md` §9
gets an updated blocker entry and cell showing the N-6 field.

Acceptance: the section-level checks named per item in the evaluation; the phase 2 mirror
condition still holds.

---

## 7. Phase 4: evidence and handoff machinery (N-2, N-3, N-5)

One PR. Plugin version 1.1.1 → 1.2.0 (new hook, new script).

### N-2. Sha-bound evidence stamp (S)

- Files: `references/working-agreements.md`, `references/adapter-github.md` §Pull requests;
  `docs/working-agreements.md`.
- Define the literal: first line `VERIFIED: <suite or run id> @ <full head sha>`, then the
  command and its summary output. A push after the stamp voids it. `[READY]` requires a current
  stamp. Add "credit only the enforcing tool call".
- The parser lives in N-3's script; its stale-sha fixture is N-2's acceptance.

### N-3. Derived handoffs (M)

- New `skills/agentic-work-packages/assets/scripts/sync-cells.sh`. For each issue with a
  `cell:*` label, derive the label from observable state in this precedence: PR merged →
  `cell:merged`; open PR with current `VERIFIED` stamp → `cell:awaiting-review`; `BLOCKER.md`
  on the branch → `cell:blocked`; branch, no PR → `cell:active`; otherwise unchanged.
- Dry-run default, `--apply` writes. Add `--state <file.json>` so the same code path runs over
  a fixture without `gh`; the `gh` collector writes the same shape.
- Test: fixture state set covering every rule plus a stale-sha stamp that must not count as
  current.
- Docs: `coordination.md` (coordinator runs it each cycle; `HANDOFF.md` is context, never the
  routing signal; a hand-set label is a hint the next sync overwrites);
  `adapter-github.md`.

### N-5. Stop hook (M), decision required

Three legal outcomes in the evaluation. Recommendation: ship the hook, and add one sentence
pointing at N-14 for adopters running AIQT. Reason: N-4 and N-14 both state nodots must work
without AIQT, and `docs/working-agreements.md` §8 has promised this hook since commit `8cbbcd4`.

- New `hooks/require-handoff.js`: on a non-default branch (`git symbolic-ref refs/remotes/origin/HEAD`,
  falling back to `main`/`master`/`development`), with `git status --porcelain` non-empty, and
  neither `HANDOFF.md` nor `BLOCKER.md` at the branch cell dir or root, block the stop naming
  both files. Honor `stop_hook_active` in the input so a blocked stop cannot loop. Fail open
  with the N-12 stderr line. Confirm the Stop hook's block-decision contract against the Claude
  Code hooks reference at implementation time rather than from memory.
- Wire into `hooks/hooks.json` and `assets/settings-snippet.json`; `SKILL.md` step 7 mentions
  both hooks.
- Test: fixture repo in four states (default branch; feature branch clean; feature branch
  dirty with `HANDOFF.md`; feature branch dirty with neither) plus `stop_hook_active: true`.
- `docs/working-agreements.md` §8 keeps its paragraph, now true, with the AIQT sentence added.

Acceptance: fixture tests green; `hooks.json`, the settings snippet and §8 agree.

---

## 8. Phase 5: portability and AIQT seams (N-13, N-16, N-14)

One PR. Plugin 1.2.0 → 1.2.1, or folded into phase 4's bump if the branches are merged together.

### N-13 under N-16's constraint (S)

- Ship the worker contract as `skills/agentic-work-packages/assets/worker-contract.md`, not
  `AGENTS.md`. Content order fixed by the public doc §8: read `SCOPE.json` first; read
  `HANDOFF.md` if resuming; explore before writing; stopping conditions (N-7, N-8 forms);
  completion protocol (N-2 stamp, `HANDOFF.md`).
- Adopter installs it as `.claude/worker-contract.md` and adds `@.claude/worker-contract.md`
  to the hand-authored layer of `CLAUDE.md`. Document in `coordination.md`; the worked example
  in `docs/agentic-work-packages.md` shows the import line.

### N-16. Seams section (S)

- New `coordination.md` §Running with AIQT Guardrails answering the three seams:
  instruction-file ownership (above); scope declaration (`SCOPE.json` stays the source; at most
  a one-way derivation to AIQT's stricter allow-only form, never the reverse); hook coexistence.
- Seam (3) is the real work: a table of every AIQT control at `52e69c6` with its default
  (`deny`/`ask`), and the nodots disposition (`ask` mapped to deny for unattended workers, or
  a named conflict). The evaluation flags `commit-identity` and the four `ask` controls; the
  table must be complete, not just those five.

### N-14. Enumerable epic backlog (S or M), decision required

Recommendation: option (b), the provider script, sized M. Reason: option (a)'s grammar
(`- <ID> [ ] <title>`) is not GitHub's task-list syntax, so the epic checkboxes stop rendering,
and the epic body lives in the tracker, not a file, so (a) still needs an export step.

- New `skills/agentic-work-packages/assets/scripts/aei-epic.js`: reads the epic via the GitHub
  or Jira adapter, emits AEI v1 JSON, fails closed on a malformed item, accepts no item list
  from the agent. A package whose `BLOCKER.md` carries no structured kind (N-8) is emitted as
  actionable.
- Test: fixture epic bodies (one open unblocked package; all packages blocked with kind and
  reference; one malformed line) checked against the emitted JSON. The AIQT-side acceptance
  (a coordinator stop denied naming the package) is run once manually against the pinned clone
  and its transcript pasted in the PR, since CI does not install AIQT.
- Docs: registry snippet in `coordination.md`, marked optional; N-4's stopping rule stands
  without AIQT.

Acceptance: the section answers all three seams; the template filename is not `AGENTS.md`; the
seam (3) table is complete; the provider fixtures pass.

---

## 9. Phase 6: close-out

1. Turn on `check-mirror.sh` in CI if phase 2 chose the keep-and-check option.
2. Run every phase's acceptance check once more against `development` after all merges; paste
   the results into the final PR. Update the `Status` field of N-1 to N-16 in
   `HARNESS_CROSS_EVALUATION.md` with PR links; that file is gitignored and stays local, so the
   status update is a local edit, not a commit.
3. **Plugin README.** Update the feature list and layout for the Stop hook and scripts.
4. **Handoff of the H- items.** `EMERALD_HARNESS_PROPOSALS.md` already restates H-1 to H-13
   as parked-rule rows XE-1 to XE-14 plus the five cross-doc drift corrections. They travel by
   the client repo's reviewer-pen PR path and are not edited here. The only nodots-side input
   they need is the N-1-fixed `enforce-scope.js` (XE-1 / H-1) and the N-8 kind vocabulary
   (XE-13 / H-12); both exist after phases 1 and 3, so the handoff note goes out after phase 3.

---

## 10. Decisions needed before the affected phase starts

| decision | phase | recommendation |
|---|---|---|
| Mirror handling: delete the duplicate sections from `docs/`, or keep both under a check | 2 | delete |
| N-5 outcome: ship the Stop hook, delete the §8 claim, or point at AIQT | 4 | ship it, plus the AIQT sentence |
| N-14 option (a) grammar or (b) provider script | 5 | (b) |

Settled by the consolidation on 2026-09-06: one repo, private, default branch `development`, one
PR per phase; `docs/` imported from the `docs/working-agreements` branch; the evaluation
documents are gitignored and stay local.

---

## 11. Effort

| phase | items | evaluation sizes | rough total |
|---|---|---|---|
| 0 | CI, AIQT clone, branch protection | none stated | under an hour |
| 1 | N-1, N-12, N-15 | S, S, S | one to two hours |
| 2 | N-10 | M | one to three hours |
| 3 | N-4, N-6, N-7, N-8, N-9, N-11 | 6 × S | two to four hours |
| 4 | N-2, N-3, N-5 | S, M, M | three to six hours |
| 5 | N-13, N-16, N-14 | S, S, M | two to four hours |
| 6 | close-out | none stated | under an hour |

Sizes are the evaluation's estimates of agent time and are labelled as estimates. Nothing here
has been measured.
