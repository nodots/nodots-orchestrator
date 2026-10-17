# HANDOFF: G4.1 — implemented, tests green, not yet committed or PR'd

## Exploration
- `fleet doctor` (`plugins/fleet/bin/fleet.js:123-153`) does not check CI. Launch (`plugins/fleet/src/launch.js`) checked mode, target and trust only. Nothing to reuse.
- `launch-<stage>` alarms come from `plugins/fleet/src/cycle.js:189-192`; `FAULT` at `cycle.js:212` already matches `^launch-` and `^unlaunchable$`.

## Done (uncommitted)
- `tracker.js`: `ciStatus(repo, branch)`, memoized per Tracker; a failed query returns `ok:false`.
- `config.js`: `ciMaxAgeDays` (default 14, positive integer).
- `launch.js`: stages `ci-check-failed`, `ci-disabled`, `ci-stale` after the trust check, before the dry-run return.
- `scope.js`: `execution.verifiedBy` non-empty string when present, required for `model: cheapest`.
- Docs: `scope-contract.md`, `cell.md`, fleet `SKILL.md` alarm list, fleet `README.md`; blast radius stated as not checked.
- Tests: `plugins/fleet/tests/ci-preconditions.test.sh` (failed 21 of 25 before the change, 25/25 after), `stubs/gh.js` extended.
- `bash scripts/test.sh`: ALL PASS.

## Next
1. Read the reviewer subagent's report (spawned, result pending); fix any confirmed bug.
2. Commit, push, open `[READY]: G4.1` PR with `Closes #31`.
3. Post the `VERIFIED: <suite> @ <head sha>` comment with the `bash scripts/test.sh` summary.
4. No lint or build step exists in this repo; `scripts/test.sh` is the one command.

## Plan check

Package issue still matches: yes
