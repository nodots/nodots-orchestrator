# HANDOFF: C0.1 — integrationBranch

## Done

- `plugins/fleet/src/config.js`: optional `targets[].integrationBranch`
  (branch-name checked), `targets[].autoMerge` (boolean, default `false`, set
  on every target), top-level `protectedBranches` (default `[]`). Validation
  refuses a protected `integrationBranch` (`main`, `master`, `develop`,
  `development`, the target's `defaultBranch`, `protectedBranches`) and
  `autoMerge: true` without one; each error names the key. `isProtected(cfg,
  target, branch)` is exported for C0.2.
- `plugins/fleet/src/launch.js`: `baseBranch`/`baseRef` (`origin/<integrationBranch>`
  else `origin/<defaultBranch>`) used by the manifest read, the worktree
  manifest comparison, the settings read, `checkIsolation`, the worktree start
  point and the prompt's PR base. `checkIntegrationBranch` runs in `launch()`
  after the CI check and before the standards read; a missing
  `refs/remotes/origin/<integrationBranch>` in the clone is refused
  `integration-branch-missing` (alarm `launch-integration-branch-missing`)
  naming `git push origin <defaultBranch>:<integrationBranch>`.
- `plugins/fleet/bin/fleet.js`: `fleet doctor` prints `base ref <repo>: <ref>`
  per target, ok or FAIL by whether the clone has it.
- `README.md` (new "Integration branch" section) and `skills/fleet/SKILL.md`
  (base-ref rule, new alarm entry).
- `plugins/fleet/tests/integration-branch.test.sh`: 59 checks; 51 failed on the
  pre-change tree, all pass after.

## Decisions a reviewer should know

- The CI freshness check still reads `defaultBranch` (`launch.js` ci block):
  the package did not name it, and CI on a fresh integration branch may never
  have run.
- Existence is judged on the clone's remote-tracking ref, not `ls-remote`,
  because the manifest and settings reads use that same local ref.
- `autoMerge` is validated and stored only; nothing acts on it yet.

## Next

C0.2 uses `isProtected` and `autoMerge`.

## Plan check

Package issue still matches: yes
