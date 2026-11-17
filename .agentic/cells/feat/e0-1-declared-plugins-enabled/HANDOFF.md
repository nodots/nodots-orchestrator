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
- Six new fixtures; `settings` field in the fixture format.
  `invalid-unknown-key-plugin.json` gained a `settings` enabling its plugin so
  it still yields exactly its one defect through the CLI.
- `sv0-standards-gate.test.sh:49-65` (outside the lane, must pass unchanged)
  has its own materializer that ignores `settings`. So:
  - `valid.json` no longer declares `plugins`: in sv0 it would have no
    settings file and fail. `valid-plugin-enabled.json` covers a valid declared
    plugin, including `--json` normalization.
  - `invalid-settings-not-json.json` lists `.claude/settings.json` in `files`
    (written as `# .claude/settings.json`) instead of using `settings`, so both
    materializers track the same non-JSON file. Its `expect` carries the
    Node 20+ `JSON.parse` message; CI pins Node 20 (`.github/workflows/ci.yml:20`).
  - `invalid-unknown-key-plugin.json` in sv0 also prints the not-enabled line;
    sv0 asserts `contains`, so it passes.
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

## Coordinator decisions E0.2-B1 and E0.2-B2 (2026-11-17), which apply to E0.1

Recorded on #219. They apply to every package in this epic until H0.8 (#226) merges.

- Open the `[READY]:` PR.
- Wait for the CI `Fixture tests` job to pass at the PR head sha.
- Stamp `VERIFIED: ci-<run id> @ <full head sha>`, with the run URL. Quote the
  local run. A local red file is excepted only when every failing assertion in it,
  or in the nested run it reports, is `gitleaks exited 126 ... Exec format error`.
  Today that is `check-secrets.test.sh`, `gate-h-hardening.test.sh` and
  `v0-gate.test.sh`. Any other red still blocks.
