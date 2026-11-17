# HANDOFF: E0.2 — `run-checks.js`

## Done

- `plugins/agentic-work-packages/skills/agentic-work-packages/assets/tests/run-checks.test.sh`
  was committed first (cec4c67) and failed against that tree: 39 of 49 checks
  red, the first being `run-checks.js exists`.
- `plugins/agentic-work-packages/skills/agentic-work-packages/assets/scripts/run-checks.js`
  added. Node builtins only. It requires `validateFile` and `validateStandards`
  from `check-standards.js` (`check-standards.js:288`); that file is unchanged.
  - Head: `validateFile(root)`; defects printed as `standards: .claude/standards.json: <d>`,
    the shape `check-standards.js:281` uses; exit 2.
  - Base: `git rev-parse --verify <base>^{commit}` first, so a bad ref is
    reported as `run-checks: cannot resolve base <ref>` and not misread as "no
    manifest". Then `git ls-tree -r -z --name-only <base>`, and
    `git show <base>:.claude/standards.json` through `validateStandards`.
    Missing: `run-checks: no .claude/standards.json at <base>`. Base defects and
    warnings are prefixed `standards: <base>:.claude/standards.json: `, so they are
    told apart from the head's.
  - Checks: `sh -c` with cwd `<root>`, stdio inherited, every check run, then
    `PASS  <name>` / `FAIL  <name> (exit <n>)`. A check killed by a signal prints
    `(signal <SIG>)` and still counts as a failure. The last line is the tally.
- Test cases: all pass (0), one of two fails (1, both run), head invalid or
  missing (2), base missing or invalid (2), base file list from the base tree,
  unresolvable base (2), head rewrites `false` to `true` (1, committed and
  working-tree), head-only check does not run, warnings on stderr with the exit
  code unchanged, usage error (2).

## Next

- E0.3 documents the script in `references/standards.md` (out of this lane).
- The workflow that calls `run-checks.js --base <PR base sha>` is a later package.

## Plan check

Package issue still matches: yes
