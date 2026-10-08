# Features that span repos

Use this when one feature needs changes in several repos that depend on each
other, for example a types repo, a core repo and an API repo in a chain. Each
repo gets its own package, branch, PR and merge, and they must be coordinated.
The plugin's rules on this are in other files and are not repeated here: two
repos is always two packages (`cell.md` §Sizing); the issue graph lives in one
host repo and each package names its target repo (`adapter-github.md` §Where the
hierarchy lives and §Several target repos); merge order and the release step
are in `working-agreements.md` §Multi-repo sequencing. This file adds the
mechanics of running the chain.

## The dependency chain

```
types -> core -> api
         core -> client
```

A feature touching types, core and api produces three packages, one per repo,
merged in that order.

## Principles

1. **Same feature slug across all repos**, so the relationship is visible. Each
   branch name still carries its own package ID (`SKILL.md` §Numbering rules).
2. **Same base branch across all repos**, where the repos share one. Verify
   before creating branches; see §Common mistakes.
3. **Build and commit in dependency order**: types first, core second, api
   last.
4. **Each PR states which PRs must merge before it.**
5. **Merge in dependency order.** Never merge a downstream PR before its
   upstream dependency.

## Step by step

### 1. Create the branches

Same slug, same base, every repo. This loop assumes the repos are checked out
side by side under `packages/`. Under the isolation rule in `coordination.md`
§Isolation each package still works in its own worktree; the branch is cut from
the same base either way.

```bash
for pkg in types core api; do
  cd packages/$pkg
  git checkout -B feat/<feature-name> <base-branch>
  cd ../..
done
```

### 2. Implement in dependency order

Build and verify each repo before moving to the next:

```
types:  write code -> npm run build -> commit
core:   write code -> npm run build -> npm test -> commit
api:    write code -> npm run build -> commit
```

Each repo consumes its upstream through a `file:../types` or `file:../core`
dependency, so the freshly built `dist/` of the upstream is picked up
automatically.

### 3. Push all branches

```bash
for pkg in types core api; do
  cd packages/$pkg
  git push origin feat/<feature-name>
  cd ../..
done
```

### 4. Open the PRs in dependency order

Each PR targets the same base branch and documents the chain:

| Order | Repo | PR body includes |
|---|---|---|
| 1 | types | "No dependencies. Merge first." |
| 2 | core | "Depends on types PR #N. Merge second." |
| 3 | api | "Depends on types PR #N and core PR #M. Merge last." |

Include this section in every PR body:

```markdown
## Cross-repo merge chain
- [ ] types PR #N (merge first)
- [ ] core PR #M (merge second, depends on types)
- [ ] api PR #P (merge last, depends on both)
```

### 5. Merge in dependency order

Follow `merge-procedure.md` for each PR, strictly in order:

1. Merge the types PR, then rebuild types.
2. Merge the core PR, then rebuild core and run its tests.
3. Merge the api PR, then rebuild api and run its migration (§Schema
   migrations).

After each upstream merge, the downstream branch may need a rebase if the base
branch moved.

### 6. Verify the whole chain

After all PRs are merged, confirm the full chain builds:

```bash
cd packages/types && npm run build
cd ../core && npm run build && npm test
cd ../api && npm run build
```

## Schema migrations

When the API repo includes a schema migration (drizzle is the example tool
here; use the equivalent commands for yours):

1. Generate the migration on the feature branch: `npx drizzle-kit generate`.
2. Commit the migration SQL and the snapshot files.
3. After the merge, run `npx drizzle-kit migrate` against the target database.
4. Confirm the migration applied cleanly.

Regenerate the migration if the base branch's schema changed during
development; a stale snapshot drifts. Before step 3, confirm which database
the command is aimed at (`working-agreements.md` §Deploy verification means
exercising the feature). `cell.md` §Sizing separates a migration from feature
code; where the plan does that, the migration is its own package and the one
that owns `migrations/**`.

## Common mistakes

**Wrong base branch.** Each repo may have a different default branch. Confirm
the base for each repo before creating branches.

**Building out of order.** If api is implemented before types is built, the
`file:../types` reference resolves to stale `dist/` output. Build upstream
first.

**Merging out of order.** If core merges before types, core's CI fails because
it imports types that do not yet exist on the base branch.

**Forgetting to regenerate the migration.** If the base branch gained schema
changes after the work started, the migration can include unrelated ALTERs or
conflict with existing migrations. Regenerate before the merge if the base
moved.

## Tracking the chain

Record the chain as one group in the epic's progress log (`coordination.md`
§The logs), listing the PRs in merge order:

```markdown
### <feature> (cross-repo, merge in order)
1. acme-types PR #<n>: types
2. acme-core PR #<n>: logic and tests
3. acme-api PR #<n>: schema, routes, migration
```
