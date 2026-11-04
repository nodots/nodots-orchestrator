# Merging a completed package

Use this when the coordinator merges a package whose PR is `[READY]`: the checks
to pass first, the order to merge in, the steps for one merge, and what to do
when a merge fails. It assumes the package was executed under the rules in
`coordination.md` and `working-agreements.md`, and does not repeat them.

## Branch flow per repo

Not every repo merges to its default branch. Check the target branch before
merging. Where this file says `<target>`, substitute the repo's own.

| Repo | Feature target | Promotion path |
|---|---|---|
| `acme-api` | `main` | feature -> main |
| `acme-web` | `<release-branch>` | feature -> `<release-branch>` |
| `acme-platform` | `development` | feature -> development, never directly to main |

A feature that spans repos has an additional procedure: see `cross-repo.md`.
The rule that governs it is that upstream repos merge first and downstream
repos last.

## Pre-merge checklist

Before merging any package:

- [ ] The PR title carries `[READY]:` and the package ID, and a current
      `VERIFIED:` stamp exists for the head sha (`adapter-github.md` §Pull
      requests and §The evidence stamp)
- [ ] All CI checks pass
- [ ] `HANDOFF.md` on the branch is complete and clear
- [ ] No dependency merged since the package was cut affects it
- [ ] Every branch in `SCOPE.json.dependsOn` is already merged to `<target>`
- [ ] No merge conflicts will occur (the CI integration check should verify
      this)

If any item is false, do not merge. Leave feedback on the PR, mark the package
not ready, and wait for the cause to be resolved.

## The merge sequence

Merge in dependency order: packages with no unmet dependencies first, then the
packages that depend on them.

```
Package A: no dependencies   -> merge 1
Package B: depends on A      -> merge 2, after A
Package C: depends on B      -> merge 3, after B
Package D: no dependencies   -> merge any time; it does not touch A to C
```

## Merge steps

Run these for one package at a time.

**Setup.** Confirm the working directory is the right repo and is clean:

```bash
git status
# Expect: on the target branch, "nothing to commit, working tree clean"
```

If it is not clean, stop and investigate before merging.

**1. Fetch.**

```bash
git fetch origin
```

**2. Screen the diff.** Read it with the two-dot diff and decide with
`git merge-tree`, as in `coordination.md` §Before merging: which diff you are
reading. A branch cut from a stale base that reverts advanced files is rebased,
not merged.

**3. Rebase the feature branch onto the target.**

```bash
git checkout <feature-branch>
git rebase origin/<target>
```

If the rebase conflicts, resolve the files, `git add <files>`, and
`git rebase --continue`. If it fails outright, `git rebase --abort`, return the
package to the coordinator workflow, and coordinate with the worker.

**4. Run the final tests: the changed package and everything that imports it.**
CI may run broader checks, but the coordinator verifies at least this set
locally.

Identify the changed package from the diff or from `SCOPE.json` `allowedPaths`:

```bash
git diff origin/<target> --name-only
```

The top-level directory of each changed file names the package. Then find the
packages that depend on it, by searching sibling imports or sibling dependency
manifests:

```bash
grep -r "from.*<changed-package>" packages/*/src --include="*.ts" -l
```

For example, a change to `acme-types` is tested in `acme-types` and in
`acme-core`, because core imports types. Run every check in the changed
package's `.claude/standards.json`, then every check in each dependent's, each
in the order its manifest lists them:

```bash
cd packages/<changed-package> && <each check command, in manifest order>
cd packages/<dependent-package> && <each check command, in manifest order>
```

The merge procedure names no tool; the commands are the repo's, read from its
manifest (`standards.md`). All must pass. If any fails, abort, mark the PR not ready, and leave feedback.

**5. Merge to the target.** Squash for features:

```bash
git checkout <target>
git pull origin <target>
git merge --squash <feature-branch>
```

`--squash` combines the branch's commits into one and keeps the history clean.
For a contract change use a merge commit instead, which preserves the full
history (`contract-change.md`):

```bash
git merge --no-ff contract/<change-name>
```

**6. Write the commit message.** It carries a `[MERGED]` prefix, the feature
name, the PR number, and a one-line description:

```bash
git commit -m "$(cat << 'EOF'
[MERGED] <feature name> — PR #<number>

<One-line description of what was implemented.>
EOF
)"
```

**7. Tag the commit.**

```bash
git tag -a <feature-branch> -m "Merged <feature name>"
```

A tag named exactly like the branch makes the name ambiguous. In a local test
of this sequence, `git push origin <feature-branch>` failed with `src refspec
<feature-branch> matches more than one` once the tag existed. Push the tag by
its full ref in the next step.

**8. Push.**

```bash
git push origin <target>
git push origin refs/tags/<feature-branch>
```

**9. Verify the merge on GitHub.** The PR closes, the commit appears on the
target branch, and CI runs on the target and passes. If the PR did not close:

```bash
gh pr close <PR-number>
```

**10. Record it** in the epic's progress log (`coordination.md` §The logs). See
§Record keeping.

## Handling merge failures

**Rebase conflicts.** Resolve as in step 3. If the resolution is complex,
consult the worker or the team.

**Tests fail after the rebase but passed before.** The target branch has a
change that conflicts with this feature. Options:

1. The worker rebases the feature branch and re-runs the tests.
2. Defer the merge until the conflicting change on the target is understood.
3. Pair on the resolution with the worker.

Do not force-merge failing tests.

## Mistakes to avoid

- **Force-pushing the target branch after a merge.** Once merged, leave it. To
  undo, create a revert commit.
- **Merging without running tests.** A `git merge --squash` followed by a push
  skips the check in step 4.
- **Merging out of order.** If package B depends on package A, merging B first
  is wrong. Read `dependsOn` in `SCOPE.json` and merge the dependency first.
- **Skipping the final look.** Before the merge, check what is going in:

```bash
git log origin/<target>..HEAD   # which commits are being merged
git diff origin/<target>        # which code changes
```

If it looks wrong, stop and investigate.

GitHub's merge queue is not recommended here. It merges when checks pass and
gives up control of the order, which dependency-aware merging needs.

## Record keeping

After each merge, add an entry to the epic's progress log:

```markdown
Merge #<n> — <timestamp>

**Package:** <package ID and branch>
**PR:** #<number>
**Commits:** 1 (squashed)
**Status:** success

**Checks run** (named as in `.claude/standards.json`):
  - <check name>: <summary output, e.g. count passing>
  - <check name>: OK

**Next ready:** <package> (depends on this one, now unblocked)
```

The entry helps debug problems and track the pace of the run.

## Rollback

If a merged package breaks the target branch:

```bash
git revert <merge-commit-hash>
git push origin <target>
```

A revert commit adds an undo without rewriting history, which is much safer than
`git reset --hard`. Do not use `git reset --hard` unless explicitly authorized,
because it rewrites history and can lose work.

Then:

1. Notify the team.
2. Investigate the root cause.
3. The worker fixes the issue on the feature branch.
4. Re-merge with the fix.

## Summary checklist

Before every merge:
- [ ] All CI checks pass
- [ ] Dependencies are merged
- [ ] Tests pass locally in the changed package and every package that imports it
- [ ] `HANDOFF.md` is complete

During the merge:
- [ ] The rebase has no unresolved conflicts
- [ ] The final test run passes
- [ ] The commit message is clear
- [ ] The tag is created
- [ ] The push succeeds

After the merge:
- [ ] The PR is closed
- [ ] The progress log entry is written
