# BLOCKER: S2.1 — two fleet suites outside the lane launch into fixtures with no .claude/settings.json

**Bucket:** blocked on a decision
**Kind:** human-decision
**Reference:** #128 (S2.1), lane `.agentic/cells/feat/s2-1-operator-isolation/SCOPE.json`
**Owner:** the coordinator
**Un-blocks when:** #128's `### SCOPE.json` adds `plugins/fleet/tests/standards-launch.test.sh` and `plugins/fleet/tests/sv1-standards-gate.test.sh` to `allowedPaths`, or a decision on #128 or the epic (#117) picks another option below

## What was needed, and why

`isolateWorkers` defaults to `true` (`plugins/fleet/src/config.js`, as #128
specifies). With isolation on, `launch()` refuses `hooks-missing` for a target
whose `origin/<defaultBranch>` has no `.claude/settings.json`
(`plugins/fleet/src/launch.js`, `checkIsolation`, called just before the
dry-run return in `launch`). #128 handles the fixture side through
`fixture_standards` in `plugins/fleet/tests/lib.sh`, which now commits a
settings file that enables `agentic-work-packages@example-market`. Two suites do
not call that helper. Each builds its own fixture with no settings file:

- `plugins/fleet/tests/standards-launch.test.sh`: its own `publish()` (`:40`).
  73 checks, 17 failed: every check in B, E and G. Case E's manifest also
  declares `fleet@nodots` (`:136`), so that suite would be refused
  `plugin-missing` too, even with the hooks plugin enabled.
- `plugins/fleet/tests/sv1-standards-gate.test.sh`: its own clone (`:29-39`).
  46 checks, 17 failed, starting with "1: the dry run launches on the drafted
  manifest" and "2: the applied cycle launches".
- `scripts/tests/v0-gate.test.sh` fails 2 of 11 only because it requires
  `test.sh` to end `ALL PASS`.

`bash scripts/test.sh` at `488d6ed` ends `FAILED`. Every other suite passes,
including `standards-isolation.test.sh` (43 checks, 0 failed) and
`fixture-standards.test.sh` (20 checks, 0 failed). #128 also says "The existing
fleet suites must pass unchanged", so the acceptance criterion "`bash
scripts/test.sh` ends `ALL PASS`" cannot be met inside this lane.

## Alternatives searched
- Make `hooks-missing` skip a target with `"standards": "off"`: this does not cover standards-launch E/G or sv1 phases 1 and 2, which have a manifest. #128 also gates both checks on `isolateWorkers` alone.
- Default `isolateWorkers` to `false`: this contradicts #128 ("a boolean, default true"), and the leak would stay open by default.
- Have `fixture_standards` cover these suites: they never call it, and adding the call means editing them.
- Edit the two suites through a shell redirect: worker contract §1 forbids routing around the lane.
- Treat a target with no settings file as passing: that is a fallback that launches a worker without its scope hook, the outcome spike W1 showed. Worker contract §4 forbids it.

## The ask
S2.1-B1: how do standards-launch.test.sh and sv1-standards-gate.test.sh meet the isolation default? Options:
- (a) Add both files to the lane. Each fixture commits a `.claude/settings.json` that enables `agentic-work-packages@example-market`. standards-launch also enables the plugin its case-E manifest declares.
- (b) Add both files to the lane. Each sets `"isolateWorkers": false` in its fleet config, since `standards-isolation.test.sh` already covers isolation.
- (c) Default `isolateWorkers` to `false`.

Recommendation: (a). It keeps those suites on the default path production takes, and the edit is a few lines in each fixture setup.

Decide by: the next coordinator cycle. Cost of waiting: S2.1 and its `[READY]` PR stall. Nothing else in the lane is left to do.
