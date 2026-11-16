# The SCOPE.json contract

`SCOPE.json` is what makes unattended parallel execution safe. It states, as
paths, exactly what one agent may touch — and a PreToolUse hook enforces it, so
the boundary holds whether or not the agent is paying attention.

Without mechanical enforcement this is a comment, and lanes will be crossed.

## Fields

```json
{
  "feature": "route-authorization",
  "project": "my-project",
  "branch": "feat/route-authorization",
  "allowedPaths": ["src/routes/orders.ts", "src/middleware/**", "src/**/*.test.ts"],
  "forbiddenPaths": ["src/websocket/**", "migrations/**", "package.json", ".github/**"],
  "dependsOn": ["feat/upstream-thing"],
  "estimatedScope": "auth middleware on mutating routes + caller-identity enforcement",
  "execution": {
    "model": "<cheapest | session default | strongest available>",
    "pattern": "solo | implement+review | implement+test | gate-verify",
    "window": "<context window, or the autocompact setting>",
    "agents": ["<optional named agent types>"]
  }
}
```

| Field | Meaning |
|---|---|
| `feature` | Kebab identifier; matches the branch suffix |
| `project` | Project or repo name, for logs |
| `branch` | The one branch this package uses. One package, one branch |
| `allowedPaths` | Everything the agent may edit, **including its test paths** |
| `forbiddenPaths` | Denied even if `allowedPaths` would match. Evaluated last |
| `dependsOn` | **Branch names**, not issue IDs — this is what tooling reads |
| `estimatedScope` | One line, for the coordinator's queue view |
| `execution` | The execution profile: model tier, subagent pattern, named agents. See below |

The asymmetry between `dependsOn` (branches) and the issue's `Depends on` line
(issue IDs) is intentional: one is for machines, one is for people. Both must
express the same dependency.

### The `execution` profile

`execution` says how the package is run, not what it may touch. The planner
assigns it when the package is cut, from the table in
`coordination.md` §Execution profiles; the coordinator resolves the final
profile at dispatch and logs any change.

| Key | Meaning |
|---|---|
| `model` | Worker model tier. Stated as a tier, not a model name — model names go stale, and pinning one per worker belongs on the launch command, never in a settings key a `/model` call rewrites globally |
| `pattern` | Closed vocabulary: `solo` (one worker, no reviewer), `implement+review` (the worker spawns a reviewer subagent before opening the PR), `implement+test` (an implementer/tester pair under the same `SCOPE.json`), `gate-verify` (an independent verifier proves the integration claim) |
| `window` | The context window the worker runs with, or the autocompact setting. Choosing a model chooses a window, and the window drives cost more than the per-token price does |
| `agents` | Optional named agent types, where the repo defines them |
| `verifiedBy` | Optional. A non-empty string naming the check that verifies the output: a test command, a schema, a build or a gate. Required when `model` is `cheapest`; the fleet runtime refuses a cheapest package without it as `unlaunchable`. The runtime checks that the field is present, not that the named check exists or covers the change |

Not checked: the blast radius of a package. Nothing here or in the fleet
runtime measures how much a package can touch beyond what `allowedPaths`
states; a small lane is the planner's judgment, not an enforced limit.

A package that seems to need a pattern outside that vocabulary is a signal it
was cut wrong — the same signal as a package that wants to edit its own
`forbiddenPaths`.

### Choosing allowedPaths

Narrow enough to prevent collision, wide enough to finish the job. The common
failure is forgetting tests, which makes the definition of done unreachable.

### Choosing forbiddenPaths

Always deny the **serialising paths** — anything whose concurrent edit breaks
everyone:

- frozen contracts, shared interfaces, protocol or schema packages;
- database migrations, except in the one package that owns a migration;
- dependency manifests and lockfiles;
- CI configuration;
- the other subsystem's directory, when two phases run in parallel.

A change to any of these gets its own package, dispatched alone.

## Enforcement

`assets/hooks/enforce-scope.js` is a PreToolUse hook that blocks `Edit` and
`Write` outside `allowedPaths` or matching `forbiddenPaths`. Node builtins only,
no dependencies.

Install per repo:

```bash
mkdir -p .claude/hooks
cp <skill>/assets/hooks/enforce-scope.js .claude/hooks/
# merge assets/settings-snippet.json into .claude/settings.json
```

Installing the plugin wires the same hook through its own `hooks/hooks.json`
and needs no per-repo copy. The two copies of the hook are byte-identical, and
CI asserts it.

### The control's three fields

Every control in this model states three things in one place, so a reader never
has to infer a posture from the code. `enforce-scope.js` carries them in its
file header:

| Field | Value |
|---|---|
| **Default** | deny |
| **Fail posture** | open, and loud — one stderr line naming the hook, then exit 0 |
| **Residue** | Bash-mediated writes (`sed -i`, `tee`, shell redirects, `python -c`), MCP filesystem tools, `NotebookEdit`, `MultiEdit` |

The residue is the input classes the control does not judge, and it is part of
the control rather than a footnote to it: the matcher is `Edit|Write`, an
exact tool-name match, so nothing else reaches the hook at all. A change to any
of the three fields is a change to this table, not only to the code.

### Deny, never ask

An out-of-lane write is **denied**, with the blocker instruction, and it is
never a permission ask. The hook emits no permission-decision object at all: it
writes the reason to stderr and exits 2.

An ask would hand the confined worker the click-through on its own confinement
— the actor being restrained gets to lift the restraint, which is not a
boundary. And an unattended worker has nobody to answer a prompt, so the ask
does not slow the write down; it stalls the run at a point where no
`BLOCKER.md` has been written and nothing has been handed off. A deny costs the
same worker one file and produces a `BLOCKER.md` the coordinator can act on.

### Hook hygiene for unattended agents

Three rules. They apply to every hook in a repo that dispatches unattended
workers, not only to this one.

- **An unattended agent must never land in a permission prompt.** Every
  permitted action is allow-by-rule; every forbidden one is deny-with-reason.
  A prompt in an unattended run is a stall that reads as progress.
- **A deny message never instructs a manual edit of state the hook owns.** If a
  legitimate unblock exists, build it into the program and name it in the deny.
  A message that says "delete the lock file to continue" has invited the agent
  to disarm the control, and an agent that is confined enough to be blocked is
  confined enough to take the invitation.
- **Success is silent, failure is verbose.** A hook that cannot evaluate says so
  loudly rather than exiting 0 quietly. A silent exit 0 from a broken sensor is
  indistinguishable from a clean pass, and the run keeps going as if the check
  had held.

### Scope allow rules to the package's commands

The hook judges `Edit` and `Write`; the repo's `permissions.allow` rules decide
which shell commands a worker runs without a prompt. A wildcard over an
interpreter or a container runtime, such as `Bash(node *)`, `Bash(python:*)` or
`Bash(docker *)`, lets the worker run any program through it, including one
that writes outside `allowedPaths`. It widens the residue to everything.

- Allow the commands the package and the repo's standards checks actually run,
  by path: `Bash(bash scripts/*)`, `Bash(node scripts/*)`,
  `Bash(node plugins/*)`.
- Never allow `Bash(<name> *)` or `Bash(<name>:*)` for `node`, `python`,
  `python3`, `bash`, `sh`, `zsh`, `pwsh`, `docker`, `podman`, `npx`, `deno`,
  `bun`, `ruby`, `perl`, `sqlcmd`, `psql` or `mysql`.
- A command the narrow rules miss is a prompt, and an unattended prompt is a
  stall, so check the list against `.claude/standards.json` before dispatch.

`fleet doctor` prints one `WARN` line per broad rule it finds in a target's
`.claude/settings.json` on its default branch. A `WARN` does not fail doctor or
refuse a launch.

### Resolution order for `SCOPE.json`

1. `.agentic/cells/<branch>/SCOPE.json` — branch-scoped, preferred
2. `.auto-shop/cells/<branch>/SCOPE.json` — legacy branch-scoped
3. `<repoRoot>/SCOPE.json` — fallback

The repo root comes from the hook input's `cwd` field, resolved with
`git -C <cwd> rev-parse --show-toplevel`. Only when `cwd` is absent does the
root fall back to the hook file's own location, which is correct for a manual
`.claude/hooks/` install and wrong under a plugin install, where the file lives
outside the repo entirely. In a linked worktree `--show-toplevel` returns the
worktree root, which is where that worker's `SCOPE.json` lives, so worktree
isolation is preserved.

Behaviour worth knowing before you rely on it:

- **No `SCOPE.json` present means no restriction.** The default branch and
  ad-hoc work are unaffected; enforcement applies only while a package is live.
- `SCOPE.json`, `HANDOFF.md` and `BLOCKER.md` are always writable — an agent
  must always be able to escalate.
- Branch-scoped resolution needs a resolvable branch. In a repo with no commits
  yet, `git rev-parse --abbrev-ref HEAD` fails and the hook falls back to the
  root path.
- It **fails open**: any hook error exits zero rather than blocking work, after
  the one-line stderr notice. It is a guardrail, not a security control.
- It governs `Edit` and `Write` only. Shell commands are not intercepted, so an
  agent determined to route around it can. That is a coordination signal, not a
  threat model — see the residue row above.

Everything in this section is asserted by
`assets/tests/enforce-scope.test.sh`, which runs the hook from both install
locations and from outside the repo, the way a plugin-installed hook runs.

## Worker protocol

An agent that hits a scope violation:

1. **stops**;
2. writes `BLOCKER.md` — in the required form, below;
3. does not widen `SCOPE.json`, and does not work around the block.

`BLOCKER.md` carries, at minimum: the **bucket** (blocked on a merge, on a
missing capability, on a decision, or because we stopped looking); a
machine-readable **kind** (`tracked-task`, `human-decision`, `external`,
`foreign-lease`, `not-before`) with its **reference**; the **alternatives
searched** and why each fails; the **un-block condition**; the **owner**; and
the ask in one line. The template and the kind vocabulary are in
`coordination.md` §`BLOCKER.md`.

Two consequences worth stating here, where the worker reads them:

- **"I stopped looking" is a bucket with no kind.** It fails review, and any
  tool that enumerates the backlog reads a kindless blocker as actionable
  rather than excused. Write the alternatives you searched; if that list is
  empty, the blocker is not ready.
- **A blocker is not a place to park a widened lane.** Filing one and then
  editing outside `allowedPaths` anyway is the failure the whole model exists
  to prevent.

A scope violation means the package was mis-specified. The fix is a coordinator
decision, and usually a new package. Widening the lane silently is the single
most damaging failure in this model: it is undetectable until two agents produce
conflicting work on the same file.
