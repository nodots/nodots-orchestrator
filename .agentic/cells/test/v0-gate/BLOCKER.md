# BLOCKER: V0 — throwaway PRs for red CI could not be created in this session

**Bucket:** on a missing capability
**Kind:** human-decision
**Reference:** issue #28 acceptance criterion "Both throwaway PRs show a failing CI run, linked in the gate PR, and are closed unmerged"
**Owner:** Ken Riley (repo owner / session operator)
**Un-blocks when:** a session with permission to create and push branches and open PRs records the two throwaway PR numbers and run URLs, or the criterion is dropped from #28

## What was needed, and why

The package requires two throwaway PRs, one per seeded defect, each with a red CI
run. The worker session runs with no approval surface, and
`git checkout -b test/v0-seed-syntax` was denied by the permission policy. The
throwaway branches cannot be created, so no PR can be opened and no CI run observed.

## What is done (on `test/v0-gate`, commit e228fdf, pushed)

- `scripts/tests/v0-gate.test.sh` copies the working tree (tracked and untracked,
  minus ignored files and itself) into a fresh git repo, branch `base`, HEAD on `work`.
  It then runs `scripts/test.sh` with `BASE_REF=base` against:
  - the clean copy: exit 0, `ALL PASS`;
  - a committed `plugins/v0-seed/broken.sh` (`if then fi`): non-zero, file named;
  - a committed `plugins/v0-seed/broken.js` (`function ( {`): non-zero, file named;
  - a committed `v0-seed/aws.env` holding an AWS-key-shaped id built at runtime:
    non-zero, file named, secret not in output.
- `bash scripts/tests/v0-gate.test.sh`: `--- 11 checks, 0 failed` (3m01s local).
- `bash scripts/test.sh`: every file PASS, including `scripts/tests/v0-gate.test.sh
  --- 11 checks, 0 failed`, then `ALL PASS`, exit 0.
- Not run: a mutation check (stub `check-syntax.sh` and `check-credentials.sh` to
  `exit 0` in a scratch copy and confirm the gate goes red). The permission policy
  denied that command too.

## Alternatives searched

- Create the branch with git plumbing (`commit-tree` then push `sha:refs/heads/...`)
  without a checkout: it reaches the same outward-facing result the policy just
  denied, so it works around a permission control. Not done.
- Seed the defects on `test/v0-gate` itself and let its own CI go red: that breaks
  the gate PR and leaves the defects on the branch that merges. Rejected.
- Treat the local gate test as a stand-in for the CI runs: the issue asks for CI
  evidence specifically, and only the issue can waive it. Rejected.

## The ask

V0-1: How should the throwaway-PR criterion be met? Options: (a) re-run this
worker with permission to create and push branches and open and close PRs;
(b) a human opens the two PRs; (c) amend #28 to drop the criterion. :
recommend (a). Proposed seeds, kept inside this lane: on `test/v0-seed-syntax`,
put `if then fi` on line 2 of `scripts/tests/v0-gate.test.sh`, so the fixture
runner fails it. On `test/v0-seed-credential`, add an AWS-key-shaped comment to the
same file, so `check-credentials.sh` fails it. The syntax seed exercises the
fixture runner, not `check-syntax.sh`, because `check-syntax.sh` scans only
`plugins/`, which is forbidden to this lane. : decide-by Phase 1 start :
cost-of-waiting the Phase 2 gate (#35) stays blocked and the V0 PR cannot be
`[READY]`.
