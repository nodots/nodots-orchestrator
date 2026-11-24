# HANDOFF: X0.3 — coordinators in config; foreign labels raise an alarm and hold the package

## Done
- `plugins/fleet/src/config.js`: optional `coordinators` (an array of non-empty, unique logins; `[]` when absent). `requireFleetCoordinator(cfg, login)` is checked by the cycle.
- `plugins/fleet/src/tracker.js`: `labelActors(repo, n)` (the timeline, `--paginate`, the latest `labeled` event per label) and `login()` (`gh api user --jq .login`).
- `plugins/fleet/src/provenance.js`: `foreign(cfg, issues, tracker)`. It judges open issues only, and only `agent-ready`, `cell:*` and `worker:*`. It fails closed: a label with no `labeled` event, or one from a deleted account, is flagged.
- `plugins/fleet/src/cycle.js`:
  - The login is read once. If it fails, the cycle raises `login-failed`. A login that is not in the list raises `config-invalid`. Either way the cycle stops before promote.
  - After the epic filter, it raises `label-foreign-actor` and `label-actors-failed`.
  - Held packages are left out of promote, launch, re-dispatch (`r.held`, why `label-foreign-actor`), review, rework and merge. They stay in assign with `cell:queued` stripped, and they stay in the counts.
  - A reviewer that is already running on a held package is set aside: its verdict is not judged and its PR gets no stamp. The record is kept for when the package is trusted again. The independent review found this path.
  - Both alarms make the outcome `alarm`.
- `plugins/fleet/src/scripts.js`: `runAssign(cfg, {apply, issues})` no longer lists issues a second time.
- `plugins/fleet/tests/stubs/gh.js`: serves `timeline.json`, answers `api user`, and appends a `labeled`/`unlabeled` event by `FLEET_STUB_LOGIN` on `issue edit`.
- Tests: `plugins/fleet/tests/provenance.test.sh` (new, 54 checks) and the `coordinators` cases in `plugins/fleet/tests/config.test.sh`. Both were written first and failed against the tree before the change: config 11 failed, provenance 23 failed.

## Known and left as is
- The verify stage still sees held packages. The package names only review and merge. Left for a coordinator decision.
- Dry-run behavior changed for every config: assign now sees this cycle's promotions, so the dry run previews those assignments. `--apply` behaves the same as before.
- The stub answers the timeline without running `--jq`, so the jq filter in `tracker.js` is not covered by any test.
- On Darwin arm64, `scripts/tests/check-secrets.test.sh` and `gate-h-hardening.test.sh` fail because the pinned gitleaks archive is `linux_x64` (Exec format error). This is unrelated to the change, and `scripts/**` is outside the lane. CI runs them on ubuntu.

## Next
- A coordinator reviews and merges the PR. X0.4's doctor can call `provenance.foreign(cfg, allOpenIssues, tracker)`.

## Plan check

Package issue still matches: yes
