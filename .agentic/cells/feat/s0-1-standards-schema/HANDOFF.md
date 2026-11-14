# HANDOFF: S0.1 — Manifest schema, reference and validator

## Done

- `assets/tests/check-standards.test.sh` and `assets/tests/fixtures/standards/*.json`,
  committed first (ce4de1a) and red against that tree: `check-standards.js exists`
  failed and every CLI assertion failed with MODULE_NOT_FOUND, exit 1.
- `assets/scripts/check-standards.js`: `validateStandards({ text, files })`,
  `validateFile(repoRoot, manifestPath)`, and the CLI (exit 0 / 2, stderr lines
  `standards: <path>: <defect>`, `--json` normalized output). No dependencies; the
  glob matcher is local (`globMatches`, `matchSegments`).
- `assets/standards.schema.json`: draft 2020-12, `additionalProperties: false` at
  the top level and in `checks[]`, `rules[]`, `plugins[]` items.
- `references/standards.md`: contract, readers, every validation rule, CLI and
  module API, normalization.

## Fixture layout

Each fixture is one JSON file `{ files, manifest, expect? }`. The test
materializes it as a temp git repo (files created and `git add`ed, manifest at
`.claude/standards.json`) and runs the CLI against it, so the file list always
comes from `git ls-files`. 14 invalid fixtures: the 11 defect classes in the
issue, with "unknown key" split into top, check, rule and plugin.

## Decisions made here (not stated in the issue)

- **Example commands are placeholders.** The issue says the contract is verbatim
  from the epic's §The manifest, whose example uses package-manager commands. A
  verbatim copy under `plugins/` would fail epic success criterion 1 (the
  `git grep` for those strings prints nothing). The bullets are verbatim; the
  example's `command` values are `<lint command>` etc.
- **Normalization** fills `preamble: null`, `plugins: []` and rule `paths: null`
  when absent, in canonical key order. So that a normalized manifest is valid
  input, the validator accepts `null` for `preamble` and `paths` as "absent".
- **`rules[].check` is required** (null or a check name), as the epic example
  always carries it.
- Warnings are printed on stderr on invalid runs too; they never change the exit.
- A root that is not a git work tree is exit 2:
  `cannot list tracked files: git ls-files failed in <root>`.

## Next

- S0.2 (hook), S1.1 (init), S1.2 (launcher) should `require` this file's
  `validateFile` rather than parsing the manifest.
- The schema is not exercised by a JSON Schema engine in the suite (no
  dependency is available); it parses, and its constraints mirror the validator.

## Plan check

Package issue still matches: no

#118 needs this edit, and it is NOT yet made: `gh issue edit 118` was denied by
this session's permission policy. The coordinator should change the Scope of
work bullet for `references/standards.md` from "verbatim from the epic's
§The manifest" to "verbatim from the epic's §The manifest except that the
example's `command` values are placeholders (a verbatim copy under `plugins/`
would fail the epic's first success criterion)".
