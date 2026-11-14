# HANDOFF: S2.1 operator isolation (attempt 5)

The root `HANDOFF.md` belongs to G2.4 and is not this package's.

## Done
- `0d03d50`: `plugins/fleet/tests/standards-isolation.test.sh`, written first.
  Against the pre-change tree it failed 29 of 43 checks.
- `488d6ed`, `4fb0dba`:
  - `config.js`: `isolateWorkers`, default `true`, must be a boolean.
  - `launch.js`:
    - `buildArgs` appends `--setting-sources project,local` when `isolateWorkers` is on.
    - `checkIsolation` runs after the standards read and before the dry-run return. It reads `.claude/settings.json` from `origin/<defaultBranch>` and returns the `hooks-missing` and `plugin-missing` refusals.
    - A hook counts as present when a hook command names `<hook>.js` by path, or when `enabledPlugins["agentic-work-packages@*"]` is `=== true`.
  - `lib.sh` `fixture_standards`: commits a settings file that enables `agentic-work-packages@example-market` before the manifest commit.
  - README §Standards and SKILL.md §Reading the report document the flag and both stages.
- Attempt 5, after decision S2.1-B1 (option a) and the lane re-cut:
  - `standards-launch.test.sh`: the fixture's init commit includes a `.claude/settings.json` that enables `agentic-work-packages@example-market` and `fleet@nodots`. `fleet@nodots` is the plugin case E's manifest declares.
  - `sv1-standards-gate.test.sh`: the fixture's init commit includes a `.claude/settings.json` that enables `agentic-work-packages@example-market`.
  - Only the fixture setup changed. No assertions changed, and `isolateWorkers` stays at its default. `fleet standards init` does not read `.claude/settings.json` (no match for `settings` in `plugins/fleet/src/standards.js`), so the drafted manifest in sv1 is unchanged.
  - `bash scripts/test.sh`: see the PR's VERIFIED stamp.

## Next
- Review and merge the `[READY]: S2.1` PR.

Review nits not acted on, for the coordinator:
- `hookWiredByPath` matches the script name in any command under any event.
- Option (b) accepts `enabledPlugins` without `extraKnownMarketplaces`. Spike W3 set both; #128's text requires only the first.
- Settings are not re-read in the worktree, the way `readWorktreeStandards` re-reads the manifest.

## Plan check

Package issue still matches: yes
