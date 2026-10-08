# Changing a shared contract

Use this when a worker finds that its package needs a change to a frozen shared
interface: a types package, a protocol or schema definition, a shared utility
signature. It covers how the change is requested, reviewed, implemented,
rebased onto and merged. Contracts do not change as a side effect of feature
work. A contract change is its own package, labeled `cell:contract-change`, and
it is dispatched alone (see `adapter-github.md` §Labels and `multi-account.md`
§The coordinator cycle).

## Flow

```
Worker finds it needs a contract change
        |
Worker writes BLOCKER.md with the proposed interface and stops
        |
Coordinator reads BLOCKER.md and approves or rejects
        |
Coordinator cuts a contract package: its own branch and SCOPE.json
        |
Contract package is implemented, reviewed and merged first
        |
Blocked worker rebases onto the target branch and resumes
```

Contract paths sit in every other package's `forbiddenPaths`
(`scope-contract.md` §Choosing forbiddenPaths). The worker that needs the
change cannot make it, and does not work around the block
(`scope-contract.md` §Worker protocol).

## Step 1: the worker requests the change

The worker writes `BLOCKER.md` on its feature branch, using the required header
fields in `coordination.md` §`BLOCKER.md`. For a contract change the body also
carries:

```markdown
## Current interface
<the existing declaration, in a code block, with its file path>

## Proposed interface
<the declaration after the change, in a code block, new members marked>

## Rationale
<what the package cannot implement without it>

## Affected packages
<every repo or package that uses the interface>

## Packages that must rebase afterward
<packages already in flight that touch the interface, or "none yet">

## Options considered
1. <alternative> — <why it fails>
2. <alternative> — <why it fails>
3. <the proposed change> — chosen, and why
```

The worker commits `BLOCKER.md` so the coordinator can read it from the branch,
then stops. It writes no workaround.

## Step 2: the coordinator reviews and cuts a contract package

Read the blocker, then decide whether the change is legitimate:

- Does it make sense architecturally?
- Is it backward-compatible, where that is possible?
- Does it benefit other packages, or only this one?
- Are there alternatives the worker did not list?

**If rejected**, answer on the blocker with the reason and the alternative
approach.

**If approved**, file a new package for the change (`cell.md`) and cut its
branch from the target branch:

```bash
git checkout <target-branch>
git pull origin <target-branch>
git checkout -b contract/<change-name>
```

Its `SCOPE.json` allows the contract paths and nothing else:

```json
{
  "feature": "contract-<change-name>",
  "project": "shared-contracts",
  "branch": "contract/<change-name>",
  "allowedPaths": ["contracts/**"],
  "forbiddenPaths": ["src/**", "test/**", "package.json", "tsconfig.json"],
  "dependsOn": [],
  "estimatedScope": "Small: add one interface"
}
```

The execution profile for this package type is in `coordination.md` §Execution
profiles.

The change itself, using placeholder names:

```typescript
// contracts/shared-types.ts
export interface OrderMetadata {
  createdAt: Date;
  customerName: string;
}

export interface Order {
  items: Item[];
  history: Event[];
  metadata: OrderMetadata; // new
}
```

Where the repo keeps a contracts changelog (`contracts/CHANGELOG.md` in the
source convention), add an entry in the same change:

```markdown
## <date>

### Added
- OrderMetadata interface
- metadata field on Order (required)

### Migration
// Old
const order: Order = { items, history };

// New
const order: Order = {
  items,
  history,
  metadata: { createdAt: new Date(), customerName: "Alice" },
};

- Affects: acme-api, acme-web
- Merged: <timestamp>
```

Commit, push and open the PR:

```bash
git add contracts/
git commit -m "Contract: Add OrderMetadata interface"
git push -u origin contract/<change-name>
gh pr create --title "[CONTRACT] Add OrderMetadata interface" \
  --body "Extracted from the blocker on <blocked branch>. See BLOCKER.md there for rationale."
```

The PR title also carries the package ID and the `[READY]:` prefix required by
`adapter-github.md` §Pull requests. A `[CONTRACT]` prefix is a convention for
making the change visible in a PR list.

Review it and merge it with a merge commit, not a squash:

```bash
gh pr merge <PR-NUMBER> --merge
```

Merge it promptly, because a worker is blocked on it. Merge it only when
dependent packages have been told and can rebase, and when the coordinator
controls the timing. A contract change that lands unannounced while several
workers are mid-package breaks their rebases.

## Step 3: the blocked worker rebases

The coordinator comments on the blocked package's issue: the contract change
has merged (PR number), rebase and resume.

Labels are derived each cycle, not set by hand (`coordination.md` §Labels are
derived each cycle). Per the derivation table in `adapter-github.md`, a package
reads as `cell:blocked` while `BLOCKER.md` is on its branch, so the label does
not clear on the coordinator's comment alone.

The worker then:

```bash
git fetch origin <target-branch>
git rebase origin/<target-branch>
```

It confirms the new contract is available (the typecheck or build compiles with
the new import), resumes the package, and records in `HANDOFF.md` whether it
used the new contract and anything that surprised it.

## Merge order

The contract package merges first. Dependent packages merge after they have
rebased. Merge mechanics are in `merge-procedure.md`; for a contract change use
the merge-commit variant there, so the history stays intact.

## Contract change patterns

| Pattern | What changes | Breaking | Notes |
|---|---|---|---|
| Add a new interface | New file or declaration under `contracts/` | No | PR title `[CONTRACT] Add <Type> interface` |
| Extend an existing interface | New member on an existing declaration | Depends on whether the member is required | Document the field and the migration in the changelog |
| Remove a deprecated interface | Delete the declaration, name the replacement | Yes | Every dependent package must be updated and merged first, or this PR must rebase the dependents |
| Change a shared function signature | New parameter or return type | Yes | Alternative: add a new function and deprecate the old one gradually |

## Pre-merge checklist

- [ ] `SCOPE.json` allows `contracts/**` only
- [ ] No file outside the contract paths is modified
- [ ] The changelog is updated, if the repo keeps one
- [ ] Examples and migrations are documented
- [ ] The PR is identifiable as a contract change (`cell:contract-change`, and
      `[CONTRACT]` in the title)
- [ ] The typecheck or build passes, and other packages in the same repo still
      compile
- [ ] At least one coordinator has reviewed it
- [ ] Affected packages are identified in a PR comment

## When a contract change goes wrong

**It breaks an existing package after merge.**

1. Revert it on the target branch with `git revert <contract-commit>` and push
   the revert (`merge-procedure.md` §Rollback).
2. Identify the affected package.
3. Work out the compatibility fix with the worker that owns it.
4. Re-merge the contract change, or leave it reverted and choose a better
   approach.

**Two packages request conflicting changes.** For example, one wants a field
and the other wants the interface without it.

1. Decide which is more important and implement that change.
2. Have the other package work around it, or adjust its `SCOPE.json`.
3. Or split the interface into two declarations.

## Rules

- One contract change per PR. Related changes go in sequence, each merged
  before the next is cut: type 1, then type 2 (depends on type 1), then type 3
  (depends on types 1 and 2).
- No contract edits on a feature branch. The scope hook denies the write; the
  right path is a contract package.
- No contract merge while dependents are unaware of it or cannot rebase.
