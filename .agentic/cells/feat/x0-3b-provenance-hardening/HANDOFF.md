# HANDOFF: X0.3b — provenance hardening (#259)

## Done
- **Case-insensitive logins.** `plugins/fleet/src/config.js` adds `loginKey` (lower-case); `requireFleetCoordinator` and the duplicate check in `validateCoordinators` use it. `plugins/fleet/src/provenance.js` builds its trusted set and compares actors through it. The configured list keeps its original case.
- **Timeline parse in JS.** `plugins/fleet/src/tracker.js` `labelActors` calls `gh api …/timeline --paginate` with no `--jq` and parses the raw concatenated pages (`[..][..]`) with `timelineEvents` (exported). It selects the latest `labeled` actor per label. A malformed or cut-off page is an error, which the cycle holds as `label-actors-failed`. `tests/stubs/gh.js` prints the raw timeline in pages of `GH_STUB_TIMELINE_PAGE` and refuses `--jq` loudly.
- **Verify skips held packages.** In `plugins/fleet/src/cycle.js`, the verify stage reads `syncTrusted`. A run in flight for a held package is set aside like review's: its `inFlight` is parked during the stage and restored in `finally`, and its target's `cell:awaiting-lab` rows are dropped, so nothing is posted in that slot. Trusted PRs on that target still retitle. Exception: a finished held run with `reverted !== true` is not set aside, so the stage latches the fleet on it. That path writes nothing to the PR. This came from the implement+review pass, findings 1–3.
- **Example config.** `plugins/fleet/fleet.config.example.json` no longer has `coordinators`.
- **Tests.** `tests/config.test.sh` covers case-insensitive logins and the example config. `tests/provenance.test.sh` adds scenarios F (case), G (multi-page mixed timeline plus parser edge cases) and H/H'/H''/H''' (verify: not posted or retitled, control, held in-flight run, not-reverted latch). Before the change, these failed: 34 provenance checks and 3 config checks.

## Next
- X1.5 documents `coordinators` in the README (outside this lane).
- The refusal text in the `label-foreign-actor` alarm still reads "promote, assign, launch, re-dispatch, review or merge". It was left as is so the existing B assertions pass unchanged.

## Resume
Branch `feat/x0-3b-provenance-hardening`. Run `bash scripts/test.sh`. The PR is `[READY]: X0.3b` against `development`.

## Plan check

Package issue still matches: yes
