# HANDOFF: E0.1 — declared plugins must be enabled in tracked `.claude/settings.json`

## Done

- `check-standards.js`: `validateStandards({ text, files, settings })` takes an
  optional `settings`. `undefined` skips the check (launcher, review, `fleet
  standards init` and the eval runner pass only `text` and `files`, unchanged).
  `null` or text: each well-formed `plugins[]` item whose
  `enabledPlugins["<name>@<marketplace>"]` is not present and `=== true` is
  `plugins[<i>]: <key> is not enabled in .claude/settings.json`. Non-JSON or
  non-object settings is one defect. Same test as `pluginEnabled`
  (`plugins/fleet/src/launch.js:173-176`), not imported.
- `validateFile` reads `.claude/settings.json` only when `plugins[]` is a
  non-empty array, and only when it is in `git ls-files`; otherwise passes `null`.
  A tracked file that cannot be read is `.claude/settings.json: cannot read: <code>`.
- Six new fixtures; `settings` field in the fixture format; `valid.json` and
  `invalid-unknown-key-plugin.json` gained a `settings` enabling their plugin so
  each still yields exactly its original result through the CLI.
- Tests: untracked-on-disk case, empty-plugins-with-non-JSON-settings case, a
  module table, and a loop proving every fixture gives its pre-check result
  when `settings` is omitted. Tests committed first (c00d32e) and failed 18
  checks against the pre-change validator.
- `references/standards.md`: enablement rule and defect text, when the
  validator reads the settings file, the new `settings` module input.

## Decision taken (not spelled out in the issue)

An item with a malformed `name` or `marketplace` is not checked for enablement:
it already carries its defect, and a second defect for a key that cannot exist
adds noise (keeps the existing `multi` case at 8 lines).

## Next

Nothing in this package. `launch.js` keeps its own base-ref check (out of scope).

## Plan check

Package issue still matches: yes
