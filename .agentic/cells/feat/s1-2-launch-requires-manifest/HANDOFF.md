# HANDOFF: S1.2 — launch requires a valid manifest

Stopped on BLOCKER.md (S1.2-B2): this branch is not merged with
`origin/development`, and the session could not run `git merge`.

## Done (attempt 2)
- `plugins/fleet/tests/standards-launch.test.sh`, committed first. Against the
  pre-change tree: 73 checks, 64 failed. After the change: 73 checks, 0 failed.
- `config.js`: `targets[].standards` (`validateStandardsField`), with default
  `{ "manifest": ".claude/standards.json" }`. Accepts `"off"`, or an object
  whose relative `manifest` has no `..` segment. Anything else fails, naming
  `targets[<i>].standards`. `fleet.config.example.json` shows the default.
- `launch.js`:
  - `readBranchStandards` runs `git ls-tree -r -z --name-only` and
    `git show origin/<defaultBranch>:<manifest>` in the clone, then
    `validateStandards` from `cfg.scriptsDir/check-standards.js`. It refuses
    with `standards-missing`, `standards-unreadable` or `standards-invalid`
    after the CI checks and before the dry-run return.
  - `readWorktreeStandards` re-reads the manifest after `prepareWorktree`. A
    copy that is invalid or differs from the branch read is refused
    `standards-invalid`.
  - `pathsOverlap` (the prefix rule) and `applicableRules` are exported.
  - `buildPrompt` takes `standards` and adds the checks, rules and plugins
    lines after the lane line. Without it, the prompt is unchanged, which
    `verify-config.test.sh` D asserts byte for byte.
  - The dry-run and session records carry
    `standards: {checks, rules, applicable}` or `"off"`.
- `cycle.js` copies `standards` onto the launched row. `report.js` appends
  ` · standards: <names> (<a> of <r> rules in lane)` or ` · standards: off`.
- `SKILL.md` §Reading the report covers the three new stages and the
  standards row.

## Next
1. Coordinator: merge `origin/development` (3157f7e or later) into this branch
   and push. Its diff touches no file this package changed.
2. Run `bash scripts/test.sh` and require `ALL PASS`. On the unmerged tree it
   fails only in the ten suites #140 fixed, plus v0-gate.
3. Open the `[READY]: S1.2` PR against `development` with "Closes #125", then
   stamp `VERIFIED` per the contract §6.

## Notes for review
- `readWorktreeStandards` (the changed-between-reads refusal) has no fixture
  case. The package's test list does not ask for one.
- For a target with `verify`, prompt line (a) says "VERIFIED stamp", as the
  issue words it, while that prompt also says not to post one. That is a
  wording question for the issue, not changed here.
- `pathsOverlap` is a literal string prefix, as specified, so
  `packages/webapp/**` overlaps `packages/web/**`. The test asserts this.

## Plan check

Package issue still matches: yes
