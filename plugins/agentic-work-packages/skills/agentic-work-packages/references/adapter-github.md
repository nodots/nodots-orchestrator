# Adapter: GitHub Issues

## Where the hierarchy lives

**One repository holds the whole issue graph**, even when the code lives in
several repos. GitHub sub-issue links do not cross repository boundaries, so a
hierarchy split across repos is not a hierarchy — it is a pile of issues joined
by prose.

Pick the host repo once: the umbrella or platform repo in a multi-repo setup,
the repo itself in a monorepo. Every epic, package and gate is filed there. Each
package names its **target repo** in its header line, and its PR is opened
against that target repo.

## Parentage

Two directions, both required:

- **Child to parent:** `**Part of** #406` on the package's header line.
- **Parent to child:** a checkbox line under the phase in the epic:
  `- [ ] #407 · H0.1 Auth enforcement on mutating routes`

Native sub-issues (`gh api graphql … addSubIssue`) work when everything is in
one repo, and are worth using there — GitHub then tracks completion for you. In
a multi-repo setup they are unavailable for the packages that matter, so the
checkbox list stays the source of truth. Do not maintain both half-heartedly;
pick one and keep it ticked.

## Labels

```
epic                    Large feature or collection of related issues
agent-ready             No human judgement needed — safe to dispatch
cell:queued             Dependencies merged, waiting for capacity
cell:active             An agent is working it
cell:awaiting-lab       PR open for the verifier, no current VERIFIED stamp
cell:awaiting-review    PR open, needs human review
cell:blocked            Agent stopped, needs coordinator action
cell:merged             Complete
cell:contract-change    Modifies a frozen contract — never runs in parallel
```

Create them with `assets/scripts/bootstrap-github-labels.sh`. Add one program
label per epic (`program:payments`) plus the usual domain labels so packages can
be filtered per repo and per subsystem.

`agent-ready` is often called `claude-ready`. Whatever it is called, it means one
thing: **no human judgement is required to complete this**. Human gates never
carry it.

Only the coordinator changes `cell:*` labels. Workers do not self-promote.

When workers run on other Claude accounts, a package also carries at most one
`worker:<id>` label naming its owner, written only by
`assets/scripts/assign-cells.sh`. See `multi-account.md`.

## Filing

Only the coordinator files packages and applies `agent-ready`, `cell:*` and
`worker:*`. With `FLEET_WORKER_ID` set, `require-coordinator.js` refuses; write
`BLOCKER.md`.

```bash
# package
gh issue create --repo <owner>/<host-repo> \
  --title "H0.1 — Auth + active-player enforcement on mutating routes" \
  --body-file h0-1.md \
  --label agent-ready,cell:queued,api

# then add the checkbox line to the epic body
gh issue edit <epic> --repo <owner>/<host-repo> --body-file epic.md
```

Write bodies as files, not as `--body` strings: the templates contain fenced
JSON, backticks and newlines that shells mangle.

## Queue views

```bash
# dispatchable now
gh issue list --repo <owner>/<host-repo> \
  --label agent-ready --label cell:queued --state open

# what the fleet is on
gh issue list --repo <owner>/<host-repo> --label cell:active --state open

# blocked, needs a coordinator decision
gh issue list --repo <owner>/<host-repo> --label cell:blocked --state open
```

## Pull requests

- Title starts `[READY]:` and carries the package ID.
- Body links the package issue (`Closes #407` when the merge should close it).
- One PR per package, into the target repo's default branch.
- Merge in dependency order across repos: contracts and types first, consumers
  after. A package whose dependency is published as an artifact needs a version
  bump and a release, not just a merged commit.

### The evidence stamp

Before `[READY]`, one comment on the PR carries the proof, first line
machine-readable:

```
VERIFIED: unit+e2e @ 6f1c0a4e9b2d8a15c7e340bb91d2f5a8c0e7b3d6

<check command>
142 passed, 0 skipped
```

A push after the stamp voids it — the sha no longer matches the head, and both
a reviewer and `sync-cells.sh` read that as unverified. Re-run and re-stamp.
Full rule in `working-agreements.md` §Evidence is stamped to a sha.

## Labels are derived, not passed

Run `assets/scripts/sync-cells.sh` each cycle. It reads the tracker, the
branches and the PRs, and sets each `cell:*` label from what it finds:

| Observed | Label |
|---|---|
| PR merged | `cell:merged` |
| PR open with a current `VERIFIED` stamp | `cell:awaiting-review` |
| PR open, title `[VERIFY]:`, no current stamp | `cell:awaiting-lab` |
| `BLOCKER.md` on the branch | `cell:blocked` |
| branch exists, no PR | `cell:active` |
| none of the above | unchanged |

```bash
# what would change
assets/scripts/sync-cells.sh --repo <owner>/<host-repo> --target <owner>/<code-repo>

# write it
assets/scripts/sync-cells.sh --repo <owner>/<host-repo> --target <owner>/<code-repo> --apply
```

Dry run is the default. `--state <file.json>` runs the same derivation over a
saved state file, which is how the fixture test exercises every rule without
touching a network.

### Several target repos

`--target` is repeatable, one per repo the program touches. The issue graph
lives in the host repo; the branches and PRs live wherever each package says
they do:

```bash
assets/scripts/sync-cells.sh --repo <owner>/<host-repo> \
  --target <owner>/<core-repo> \
  --target <owner>/<api-repo> \
  --target <owner>/<client-repo>
```

Each package is routed by the **Repo:** on its own header line, so a package is
only ever matched against branches and PRs in its own repo — two repos can hold
a `feat/session-store` branch without confusing each other. A bare name is
qualified with the host's owner.

**A package naming a repo you did not pass fails the run**, naming the package
and the missing repo. It does not report that package as unchanged: with no
collection to judge it against, "unchanged" would be indistinguishable from
"nothing to do", and the label would silently rot. Add the `--target` it asks
for and run again.

The script matches a PR to an issue by the `#<number>` reference in the PR, and
a branch to an issue by the package ID — which is why the numbering rules
require that ID in the issue title, the branch name and the PR title alike.
Branch matching ignores case and treats `.` and `-` alike, so package `M1.3`
finds `feat/m1-3-validation`, but it is bounded: `M1.3` never claims `M1.30`'s
branch.

## The scope hook in the target repo

Every target repo carries `enforce-scope.js` before a wave dispatches into it —
by installing the plugin, or by copying the hook into `.claude/hooks/` and
merging `assets/settings-snippet.json`. Without it, `SCOPE.json` is a comment.

The control's three fields, recorded here so a reviewer reading only the
adapter knows what the repo's lane enforcement does and does not cover:

| Field | Value |
|---|---|
| **Default** | deny — an out-of-lane `Edit`/`Write` exits 2 with the blocker instruction, never a permission ask |
| **Fail posture** | open, and loud — one stderr line naming the hook, then exit 0 |
| **Residue** | Bash-mediated writes (`sed -i`, `tee`, shell redirects), MCP filesystem tools, `NotebookEdit`, `MultiEdit` |

Full rationale in `scope-contract.md` §Enforcement. The residue is why a PR diff
is still read against the package's `allowedPaths` at review time: the hook
bounds the tools it matches, not the agent.
