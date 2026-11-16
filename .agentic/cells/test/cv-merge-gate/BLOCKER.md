# BLOCKER: CV — "each fails when broken" cannot be shown from this session

**Bucket:** on a missing capability
**Kind:** human-decision
**Reference:** #193, acceptance criterion 2 ("Each fails when the behavior it checks is broken (shown once, by hand, in the PR)")
**Owner:** the coordinator
**Un-blocks when:** a session that can run the suite against a mutated scratch copy records the six red runs on the PR, or the coordinator waives criterion 2 on #193

## What was needed, and why
Criteria 1 and 3 are met. `plugins/fleet/tests/gate-c-merge.test.sh` asserts all
six scenarios and passes: 50 checks, 0 failed, inside a `bash scripts/test.sh`
run that ends `ALL PASS`.

Criterion 2 needs each scenario shown red against a broken `src/`. `src/` is
forbidden in this lane, so the breakage has to go in a scratch copy of the tree
outside the worktree, for example `REPO_ROOT=<copy> bash scripts/test.sh`. This
worker session denies every command except `bash scripts/test.sh` run from the
worktree root. `cp -r`, `git clone` into `/tmp`, and running a test file
directly were all denied for want of approval, and the session has no way to ask
for it.

The suite was written after the behavior had merged (C0.1 to C0.3), so it cannot
follow "failing test first". Criterion 2's mutation runs are the evidence that
stands in for it, so the PR is not `[READY]` without them.

## Alternatives searched
- Mutate `plugins/fleet/src/*.js` in this worktree and revert afterwards. Fails
  because `src/**` is in `forbiddenPaths`, and a shell write would route around
  the lane (contract §1).
- Copy or clone the tree to `/tmp` and mutate the copy. Fails because `cp -r`
  and `git clone` were denied (no approval surface).
- Run `bash plugins/fleet/tests/gate-c-merge.test.sh` against a copy. Fails
  because running a test file directly was denied. Only `bash scripts/test.sh`
  runs.
- Treat the first run's reds as the demo. Fails because those four reds were
  mistakes in the suite (the scope commit under the worker's commit, and the
  fixture PRs judged in cycle 1), not broken behavior.

## The ask
CV-1: How is criterion 2 shown? Options: (a) a person or a session with shell
approval runs the six mutations below in a scratch clone of `test/cv-merge-gate`
and posts the reds on the PR; (b) the coordinator waives criterion 2 on #193. :
recommend (a). Each is a one-line change to the clone, then
`REPO_ROOT=<clone> bash scripts/test.sh`:
  1. Branching: `src/launch.js` `baseRef()` returns `origin/${target.defaultBranch}`. Expect "1: T1.1's worktree started from collection/t" to go red, since the fixture's collection/t is one commit ahead of development.
  2. Auto-merge: `src/merge.js` `stage()` returns at its top. Expect the "2:" merge checks to go red.
  3. Promotion: `src/promote.js` `mergedBranches()` returns an empty set. Expect "3: T1.2 is promoted" and "3: T1.2 is launched" to go red.
  4. Held: `src/merge.js` `GREEN` also holds `'fail'`. Expect "4: the PR with a failing check is not merged" to go red.
  5. Protected: `src/merge.js` skips the `isProtected` branch. Expect the "5:" checks to go red.
  6. Moved head: `src/tracker.js` `mergePr` omits `--match-head-commit`. Expect "6: the PR whose head moved after its checks is not merged" to go red.
: decide-by the review of the CV PR : cost-of-waiting: the version bump that ships program C stays gated on CV.

Note: this file was first written mid-session, and it was gone from the cell
directory after a `bash scripts/test.sh` run. The cause was not found. It was
rewritten as is.
