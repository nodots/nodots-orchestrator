# HANDOFF: K0.4 — a cycle acts only on its epic's packages

## Done
- `plugins/fleet/src/scripts.js:69-104`: `runAssign` hands `assign-cells.sh` the epic's open packages through `--state` (filtered by `scope.partOf`), so assignment and the WIP cap see only the epic. `--repo` stays as the target for `--apply` writes (`assign-cells.sh:183-186`).
- `plugins/fleet/bin/fleet.js:154-162`: `fleet doctor` prints `packages of epic #N: X open in <repo>, Y open outside the epic`.
- Promote, launch, reap and the report counts were already epic-filtered in `cycle.js:79-81`, `:162`, `:211`; sync already runs with `--epic` (#95). `sync-cells.sh` is unchanged.
- `plugins/fleet/tests/epic-scope.test.sh`: two epics, each with a queued package, plus a package whose Part of is `acme/elsewhere#1`; only epic #1's package is assigned and launched, the others keep their labels, and the uncollected target repo does not fail the cycle. The qualified `owner/repo#<epic>` form is not matched, per the amended scope.
- `bash scripts/test.sh` ended `ALL PASS` on this branch (epic-scope: 13 checks, 0 failed).
- A read-only review pass found no defects.

## Not done
- The red-before-green run of `epic-scope.test.sh` against the pre-change tree was not repeated in attempt 2; the session's permissions denied extracting the old tree to a temp dir.
- The branch was not merged with `development` (permission denied). Development's changes since the merge base (K0.1, K0.2) touch `plugins/fleet/README.md` in a different hunk; no other file overlaps.

## Next
- Review and merge.
- The root `HANDOFF.md` is G2.4's, left over on `development`; it is not this package's.

## Plan check

Package issue still matches: yes
