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

## Filing

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
