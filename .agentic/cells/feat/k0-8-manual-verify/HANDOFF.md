# HANDOFF: K0.8 — verify.kind manual

## Done

- `plugins/fleet/src/config.js` (`validateVerify`): `kind: "manual"` is accepted. It needs no `url` or `suite`. A `url` is refused because fleet never requests one. `suite` is optional and validated when present. `ci.gate external` is still required. The `lab-runner` validation order is unchanged.
- `plugins/fleet/src/verify.js` (`stage`): for a `manual` target the stage skips the in-flight GET and the POST. It also ignores `vs.failed` holds. It lists the `cell:awaiting-lab` PRs as `queued` notes, using the `lab-runner` ranking (gates, then deps merged, then oldest), and returns their count as `out.waiting`. The stamp/title loop runs unchanged, so a PR that is stamped at its head but not retitled is retitled `[READY]:`. On `pulls-failed`, the sync's awaiting count stands in for `waiting`. `inFlightCount` skips manual targets.
- `plugins/fleet/src/cycle.js`: the streak does not rise while `vr.waiting > 0`. On the `fleet launch` path, which runs no verify stage, `waiting` comes from `verify.manualWaiting(cfg, sync)`.
- Review (implement+review): an independent read found three issues. Two are fixed: the README overstated "no alarm" (a failed title edit can still alarm), and the `fleet launch` path did not count the manual queue. The third is the launch.js limitation below; the docs now tell users to set `suite`. The test also gained an outcome-exhaustion check, so the no-latch proof cannot pass on movement.
- `plugins/fleet/tests/verify-manual.test.sh`: 25 checks. It fails on the pre-change tree (15 failed). With only the `cycle.js` streak line reverted, the 4-cycle no-latch checks fail.
- README and the fleet SKILL.md document the kind.

## Known limitation (outside the lane)

`src/launch.js:73` interpolates `target.verify.suite` into the worker prompt. A manual target without `suite` therefore produces "(manual, suite undefined)". The prompt is otherwise identical to the `lab-runner` prompt, as the package asks. `launch.js` is a forbidden path. Workaround: give the manual target a `suite`. Follow-up: have launch.js omit the suite clause when it is absent.

## Next

None for this package beyond review and merge.

## Plan check

Package issue still matches: yes
