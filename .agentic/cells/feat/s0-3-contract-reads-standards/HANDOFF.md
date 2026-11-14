# HANDOFF: S0.3 — contract and cell-worker read `.claude/standards.json`

## Done
- `assets/worker-contract.md` §3 (`:47-59`): third habit, read `.claude/standards.json`, read the `rules[]` docs whose `paths` overlap the lane plus every rule without `paths`, and resolve a `#fragment` to the section under that heading.
- §6 step 2 (`:127-133`): run every `checks[]` command in order; a failure is a red classified under §5; an absent manifest ends in `BLOCKER.md` (on a missing capability, human-decision, coordinator).
- §6 step 4 (`:138-150`): the stamp body lists each check by name; the first line keeps the `VERIFIED: <suite or run id> @ <sha>` shape.
- `.claude/worker-contract.md`: installed copy, written by the coordinator in 8b7dfdf (decision S0.3-1); `git diff --no-index` against the asset prints nothing.
- `agents/cell-worker.md:14`: step 1 reads the manifest after `SCOPE.json`.
- No tool, package manager or command named: the AC1 grep prints nothing.
- Completion check per decision S0.3-3 (the manifest does not exist until S0.5): `test` → `bash scripts/test.sh`, ends `ALL PASS`.

## Next
- Review and merge. Once S0.5 publishes `.claude/standards.json`, later packages run its `checks[]` instead of the S0.3-3 stand-in.

## Plan check

Package issue still matches: yes
