# BLOCKER: K0.4 — the `owner/repo#<epic>` form of **Part of** needs `cycle.js`, which the lane forbids

**Bucket:** blocked on a decision
**Kind:** human-decision
**Reference:** nodots/nodots-orchestrator#103 (Scope of work, first bullet); `plugins/fleet/src/cycle.js:81`
**Owner:** the K0 coordinator (author of #103)
**Un-blocks when:** #103 either drops the qualified form from its scope, or its SCOPE.json allows `plugins/fleet/src/cycle.js`

## What was needed, and why

#103 says a package belongs to the cycle when its `**Part of**` names `#<epic>`
"or the host repo's full `owner/repo#<epic>`". The cycle filters the issue list at
`plugins/fleet/src/cycle.js:81` with `scope.partOf(i.body) === cfg.epic`. The call
passes no host repo, so `partOf` cannot tell `acme/host#1` (this epic) from
`acme/elsewhere#1` (another repo's #1). Accepting the qualified form needs that
line to pass `cfg.repo`, and `cycle.js` is in `forbiddenPaths`.

Accepting the qualified form only in the in-lane stages (sync, assign, doctor)
would leave the stages inconsistent. The sync would derive labels for a
qualified-form package and assign would label it, while the cycle would never
launch it or count it.

## Done on this branch, in lane

- `plugins/fleet/src/scripts.js`: `runAssign` gives `assign-cells.sh --state`
  only the epic's open packages, with `--repo` so that `--apply` can write. Another
  program's queued package is no longer assigned or counted toward the WIP cap.
- `plugins/fleet/bin/fleet.js`: `fleet doctor` prints
  `packages of epic #<n>: <in> open in <repo>, <out> open outside the epic`.
- `plugins/fleet/tests/epic-scope.test.sh`: covers every acceptance criterion in #103.
  The qualified form is not tested, because it is not implemented.
- `bash scripts/test.sh` ends `ALL PASS`. Before the change, `epic-scope.test.sh`
  failed 7 of 15 checks: assign labeled #20 and #30, and doctor printed no counts.

The sync's `--epic` filter and the cycle's filter already existed (`cycle.js:81`,
`sync-cells.sh:249`) and are unchanged.

## Alternatives searched

- Make `partOf(body, repo)` accept the qualified form when `repo` is given — `cycle.js:81` passes no repo, so the cycle would still exclude these packages while sync and assign included them.
- Accept any `<owner>/<repo>#<n>` when no repo is passed — the cycle would then promote and count `acme/elsewhere#1` packages as epic #1's, writing labels outside the epic.
- Pass the host repo to `partOf` through `Tracker.listIssues` or module state — a hidden side channel into a pure function, which `cycle.js` would not know it depends on.
- Filter in `Tracker.listIssues` — `cycle.js` calls it with the repo only, so the epic cannot reach it without editing `cycle.js`.

## The ask

K0.4-1: Support `**Part of** owner/repo#<epic>`? Options: (a) add `plugins/fleet/src/cycle.js` to this package's allowedPaths so that line 81 can call `scope.partOf(i.body, cfg.repo)`; scope.js and sync-cells.sh then gain the matching rule, which is about 10 lines and a test case. (b) Drop the qualified form from #103 and merge this branch as it stands. : Recommend (b) if no live package uses the qualified form, otherwise (a). : decide-by the next applied cycle for Traffic-Tech/ttsls-dev-lab#685 : cost-of-waiting: this branch's fixes do not land, so the other program's packages in that host repo are still assigned
