# Worker contract

You are executing one work package. This file is the contract every worker in
this repository runs under. It is checked in, so it is reviewed like code and
it is the same for every worker — not a prompt someone assembled at dispatch.

Read it in order. The order is the order of operations.

---

## 1. Read `SCOPE.json` first

Before anything else, read the `SCOPE.json` for this branch:

1. `.agentic/cells/<branch>/SCOPE.json`
2. `.auto-shop/cells/<branch>/SCOPE.json`
3. `<repo root>/SCOPE.json`

It states your lane: `allowedPaths` is everything you may edit, `forbiddenPaths`
is denied even where `allowedPaths` would match. A `PreToolUse` hook enforces
both. The hook judges `Edit` and `Write` only — writes through a shell command
are not intercepted, and routing around the lane that way is a worse failure
than the one the hook stopped, because nobody sees it.

**Do not widen the lane.** Not by editing `SCOPE.json`, not by asking for it to
be widened, not by a shell redirect. A lane you need to widen is a package that
was cut wrong, and that is a coordinator decision.

## 2. If you are resuming, read `HANDOFF.md`

A previous worker may have left `HANDOFF.md` at the repo root or in this
branch's cell directory. It is context — what was done, what was learned, what
comes next. It is not your instructions and it is not a routing signal; the
package issue and `SCOPE.json` are.

If `BLOCKER.md` is present, this package is stopped and waiting on a decision.
Read it, and do not restart the work it describes until the decision is
recorded.

## 3. Explore before writing

Read the code you are about to change, and the code that calls it, before you
change anything. Cite what you find as `file:line` — in your reasoning, in the
PR, in `HANDOFF.md`. A claim about the codebase with no file and no line is a
guess, and it will be wrong in the way that is most expensive to discover.

Two specific habits:

- **Verify an external fact at its source before building on it.** If the check
  is cheap, the check is the next action, never the inference.
- **Confirm which repository the shell is in** before running anything. In a
  workspace of siblings, the previous command's directory is the most common
  cause of a command run in the wrong place.

## 4. Prove it, do not assert it

- **Write the failing test before the change.** It must fail against the
  pre-change tree and pass after. A test written afterwards proves the code
  runs, not that the bug is gone. If you cannot make it fail, you do not yet
  understand the bug — that is a stop, not a licence to proceed.
- **A bug fix ships a regression fixture built from the real failing input**,
  not an approximation of it.
- **A UI change is not done without a browser-driven end-to-end test** that
  exercises the acceptance criteria.
- **Never add a fallback that substitutes a different answer** when the intended
  one cannot be produced. Throw, log the inputs and what was tried, and stop. A
  fallback turns a detectable failure into a plausible wrong answer.
- **"Should now work" is not a status.** Report what you ran and what it
  printed.

## 5. Stopping conditions

**Classify a red before retrying it.**

- A *deterministic* red — the same failure shape twice, or a single failure that
  maps to a readable code path — gets **zero** re-runs. It is a diagnosis
  assignment.
- An *infrastructure* red — missing resource, crashed worker, transient 5xx —
  gets **exactly one** re-run. A second identical red retires the flake
  hypothesis for good.
- Never re-run a suite until it passes, and never relax an assertion until it
  holds. A green produced that way tells no one anything.

**Stop and write `BLOCKER.md` when:**

- you need to edit a path outside `allowedPaths`, or a frozen config file;
- a deterministic red's cause is outside what this package may change, or is not
  decidable from the artifacts you have;
- you face a design decision the package does not answer;
- `SCOPE.json` looks wrong or incomplete.

`BLOCKER.md` requires, every time:

```markdown
# BLOCKER: <package id> — <one line>

**Bucket:** blocked on a merge | on a missing capability | on a decision |
            because we stopped looking
**Kind:** tracked-task | human-decision | external | foreign-lease | not-before
**Reference:** <the issue, person, service, branch or time>
**Owner:** <who can clear it>
**Un-blocks when:** <an observable event>

## What was needed, and why
## Alternatives searched
- <alternative> — <why it fails>

## The ask
<id>: <question, options inline> : <recommendation> : decide-by <event> :
cost-of-waiting <what stalls>
```

"Because we stopped looking" is the one bucket with no kind. It fails review,
and any tool that enumerates the backlog reads a kindless blocker as
**actionable**, never as excused. If the alternatives list is empty, the blocker
is not ready to file.

## 6. Completion protocol

1. The acceptance criteria are met, each one observable.
2. Tests, build/typecheck and lint pass. Run them; do not infer them.
3. Open the PR: title starting `[READY]:` and carrying the package ID, body
   linking the package issue.
4. **Stamp the evidence** in one PR comment, first line machine-readable:

   ```
   VERIFIED: <suite or run id> @ <full head sha>

   <the command you ran>
   <its summary output>
   ```

   A push after the stamp voids it — re-run and re-stamp. `[READY]` means a
   current stamp exists for the present head sha. Someone else's "tests pass"
   is a pointer to re-query, never a clearance.
5. **Write `HANDOFF.md`** before you finish: what is done, what is next, what a
   cold session needs in order to resume. A `Stop` hook blocks the turn from
   ending on a dirty branch with neither `HANDOFF.md` nor `BLOCKER.md` written.
   Committing the changes is not the alternative; the written state is the
   point.

   `HANDOFF.md` carries a required `Plan check` section. The hook blocks a
   `HANDOFF.md` that lacks it; `BLOCKER.md` is exempt.

   ```markdown
   ## Plan check

   Package issue still matches: yes
   ```

   Write `no` when what you built diverged from the package issue. Then update
   the issue in the same change, and under the line give the issue number you
   updated and what changed. The hook checks that the section and a `yes` or
   `no` are present; it does not judge whether the answer is true.

Do not change your own `cell:*` label. Labels are derived from observable state
each cycle by the coordinator, and a hand-set one is overwritten.

---

**Installing this file.** Copy it into the repo as `.claude/worker-contract.md`
and import it from the hand-authored part of the repo's `CLAUDE.md`:

```markdown
@.claude/worker-contract.md
```

It is deliberately **not** shipped as `AGENTS.md`. Some tools generate
`AGENTS.md` whole and mark it do-not-hand-edit; a contract written there would
be silently overwritten on the next regeneration. Import it from whichever root
instruction file the adopter owns.
