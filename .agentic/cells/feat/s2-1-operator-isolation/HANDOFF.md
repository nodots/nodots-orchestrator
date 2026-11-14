# HANDOFF: S2.1 operator isolation (attempt 4)

Earlier attempts left no commits on the branch. The root `HANDOFF.md` belongs
to G2.4 and is not this package's.

## Done
- `0d03d50`: `plugins/fleet/tests/standards-isolation.test.sh`, written first.
  Against the pre-change tree it failed 29 of 43 checks.
- `488d6ed` and the commit after it:
  - `config.js`: `isolateWorkers`, default `true`, must be a boolean.
  - `launch.js`:
    - `buildArgs` appends `--setting-sources project,local` when `isolateWorkers` is on.
    - `checkIsolation` runs after the standards read and before the dry-run return. It reads `.claude/settings.json` from `origin/<defaultBranch>` and returns the `hooks-missing` and `plugin-missing` refusals.
    - A hook counts as present when a hook command names `<hook>.js` by path, or when `enabledPlugins["agentic-work-packages@*"]` is `=== true`.
  - `lib.sh` `fixture_standards`: commits a settings file that enables `agentic-work-packages@example-market` before the manifest commit, so the manifest stays the last commit, which `fixture-standards.test.sh` requires.
  - README §Standards and SKILL.md §Reading the report document the flag and both stages.
- An internal review against REVIEW.md found one Important issue, the two suites in `BLOCKER.md`. One nit is fixed: the C assertion in the isolation test could not fail.

## Blocked
`bash scripts/test.sh` ends `FAILED`. `standards-launch.test.sh` failed 17 of
73 checks and `sv1-standards-gate.test.sh` failed 17 of 46. `v0-gate` fails as
a consequence. Both suites are outside the lane. See `BLOCKER.md` (S2.1-B1).
No PR has been opened.

## Next
1. Once S2.1-B1 is decided and the lane re-cut, update the two suites' fixtures (option (a): a settings file enabling `agentic-work-packages@example-market`; for standards-launch, also enable the plugin its case-E manifest declares).
2. Run `bash scripts/test.sh` to `ALL PASS`, open `[READY]: S2.1` against `development` with "Closes #128", and stamp `VERIFIED` at the head sha.

Review nits not acted on, for the coordinator:
- `hookWiredByPath` matches the script name in any command under any event.
- Option (b) accepts `enabledPlugins` without `extraKnownMarketplaces`. Spike W3 set both; #128's text requires only the first.
- Settings are not re-read in the worktree, the way `readWorktreeStandards` re-reads the manifest.

## Plan check

Package issue still matches: yes
