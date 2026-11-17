# HANDOFF: RV (#177): program R review gate

## Done

- `plugins/fleet/tests/gate-r-review.test.sh`: 50 checks, driven through `fleet cycle --apply` against a bare
  remote, the real `sync-cells.sh`, the gh and claude stubs and `tests/stubs/reviewer.sh`.
  - Fixture 1: `review: {passes: 2}`, reviewers `stub-a` then `stub-b`, packages T1.1 (PR #200, pass path)
    and T1.2 (PR #201, fail path). `REVIEWER_STUB_VERDICT_201=fail` makes stub-a fail #201. stub-b's argv
    is `env -u REVIEWER_STUB_VERDICT_201 <stub> ...`, so stub-b passes there, with no change to the stub.
  - Fixture 2: the same config with no `review` key (scenario 6).
  - `check-stamp.js` gets the input CI collects: title, head, comment bodies, and the base manifest.
  - Every stub output is waited on (`wait_for_file`, `wait_exit`) before it is read.
- `--break <1..6>` runs the suite against `git archive HEAD` in its own temp dir, with one behavior broken.
  That covers the "each scenario fails when broken" criterion without touching `src/` or `scripts/`.
  Results are in the PR body.

## Interpretation to note

Scenario 4 says "that head is not reviewed again". `review.js:307` and #175 define this per reviewer: the
reviewer that failed is not run again at that head. Another configured reviewer may still run there, as
stub-b does on #201. The suite asserts the per-reviewer rule (stub-a runs once on #201 across later cycles).
It also asserts that #201 is then `held` and never leaves `cell:awaiting-reviewer` at the failed head. If
the coordinator means "no reviewer at all", that is a change to `review.js`, which is outside this lane.

## Next

Coordinator review and merge. Nothing else is pending in this package.

## Plan check

Package issue still matches: yes
