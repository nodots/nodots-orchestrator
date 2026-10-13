# HANDOFF: V4 gate (#42)

## Done

Two gate tests, both in `allowedPaths`, both picked up by the existing globs in
`scripts/test.sh:48`.

- `plugins/fleet/tests/v4-gate.test.sh` (15 checks). Applied cycles against a
  stub target with three packages: default tier, cheapest with no
  `verifiedBy`, cheapest with `verifiedBy`.
  - Disabled CI (`{"workflows":[{"state":"disabled_manually"}]}`): issues 20 and
    22 raise `launch-ci-disabled` (`plugins/fleet/src/launch.js:167`), issue 21
    raises `unlaunchable`, `launched` is empty, no worktree dir exists, the
    claude stub log is empty, and no branch other than `main` is on the remote.
  - Healthy CI: issue 21 alone is `unlaunchable` and its detail names
    `verifiedBy`; 20 and 22 launch; the claude stub started exactly G9.1 and
    G9.3; no `g9-2` branch was pushed.
- `plugins/agentic-work-packages/skills/agentic-work-packages/assets/tests/v4-gate.test.sh`
  (30 checks). Runs the Stop event against both shipped copies of
  `require-handoff.js`, with `HANDOFF.md` at the repo root and in
  `.agentic/cells/<branch>/`. Without a Plan check: a `"decision":"block"`
  naming "Plan check", exit 0, empty stderr. With `Package issue still
  matches: yes`: empty output, exit 0, empty stderr.

Observed ordering: the `verifiedBy` check runs before the CI check, so a
cheapest package with no `verifiedBy` is reported `unlaunchable`, not
`launch-ci-disabled`, when CI is disabled. The gate asserts that ordering.

## Verification

`bash scripts/test.sh` ends `ALL PASS`; every pre-existing suite passes
unchanged.

Not done: these gate tests were run only against the current tree, which
already contains G4.1 and G4.2. They were not run against a pre-G4.1/G4.2
tree to show they fail there. Checking out an older tree needs commands
outside this session's permissions. The same behavior is covered by
fail-first tests in those packages (`ci-preconditions.test.sh`,
`require-handoff.test.sh`).

## Next

Review and merge the PR. The gate closes Phase 4.

## Plan check

Package issue still matches: yes
