# The standards manifest

A target repo publishes its coding standards in one file, `.claude/standards.json`,
next to its installed worker contract. The orchestrator ships the mechanism —
this contract, a schema and a validator — and ships no standards.

This file is the governing text. `docs/` has no copy. The schema is
`assets/standards.schema.json`; the validator is `assets/scripts/check-standards.js`.
Where this file and either of them disagree, this file governs and the other is
a defect.

## The manifest

```json
{
  "version": 1,
  "checks": [
    { "name": "lint", "command": "<lint command>" },
    { "name": "typecheck", "command": "<typecheck command>" },
    { "name": "test", "command": "<test command>" }
  ],
  "rules": [
    { "doc": "CLAUDE.md#ui-no-sx", "paths": ["packages/web/**"], "check": "lint" },
    { "doc": "CONTRIBUTING.md", "check": null }
  ],
  "preamble": ".claude/standards-preamble.md",
  "plugins": [ { "name": "<plugin>", "marketplace": "<marketplace>" } ]
}
```

The commands are placeholders: a command is whatever the repo runs, and the
orchestrator names no toolchain.

- **The repo owns it.** A change to a standard is a PR in that repo. The orchestrator reads it and never writes it, except through `fleet standards init`, which drafts to disk for a human to commit.
- **No manifest, no launch.** The launcher refuses a target whose default branch has no valid manifest, as it refuses one with CI disabled. `targets[].standards: "off"` is the one, explicit, reported exception; there is no convention fallback.
- **Checks are commands; rules are pointers.** A `check` is run and quoted in the stamp. A `rule` names the document to read, the paths it applies to, and the check that enforces it; a rule with `check: null` is allowed and reported as a warning.
- **Rules are lane-scoped.** A worker is briefed only on rules whose `paths` overlap its `allowedPaths`, plus rules with no `paths`.
- **The preamble is the repo's.** The hook prints the file the manifest names; the orchestrator ships no preamble text.

## Readers

Every reader validates through `check-standards.js`; none parses the manifest on its own.

| Reader | What it takes from the manifest |
|---|---|
| Worker contract §6 | The checks to run and quote in the `VERIFIED` stamp, and the rules to read |
| Launcher (`fleet cycle`) | Refuses a target with no valid manifest; briefs the worker on every check and on the rules whose `paths` overlap its lane |
| Preamble hook (SessionStart) | Prints the file `preamble` names |
| Eval runner | The checks a `lint` case runs in the work directory |

## Validation rules

"Tracked" means listed by `git -C <root> ls-files`. Untracked files never count,
even when they exist on disk. The manifest itself is read whether or not it is
tracked.

**The file.**

- It must exist. Otherwise: `file not found`.
- It must parse as JSON. Otherwise: `not valid JSON: <parser message>`.
- It must be a JSON object. Otherwise: `manifest: must be a JSON object`.
- The root must be a git work tree, so the tracked file list can be read.
  Otherwise: `cannot list tracked files: git ls-files failed in <root>`.

**Top level.** Allowed keys: `version`, `checks`, `rules`, `preamble`, `plugins`.
Any other key is a defect: `<key>: unknown key`.

- `version` is the integer `1`.
- `checks` is a non-empty array of objects.
- `rules` is an array of objects. It may be empty.
- `preamble`, when present and not `null`, is a string naming a tracked file.
  `null` is the same as absent.
- `plugins`, when present, is an array of objects. It may be empty.

**Each `checks[]` item.** Allowed keys: `name`, `command`. Any other key is a
defect: `checks[<i>].<key>: unknown key`.

- `name` is a string matching `^[a-z][a-z0-9-]*$`, and no earlier check has the
  same name.
- `command` is a non-empty string.

**Each `rules[]` item.** Allowed keys: `doc`, `paths`, `check`. Any other key is
a defect: `rules[<i>].<key>: unknown key`.

- `doc` is a string: a repo-relative path with an optional `#fragment`. The part
  before the first `#` must be a tracked file. The fragment is not checked.
- `paths`, when present and not `null`, is a non-empty array of non-empty glob
  strings, and each glob matches at least one tracked file. `null` is the same
  as absent; a rule with no `paths` applies to every lane.
- `check` is required. It is `null` or the `name` of a check in `checks`.
  `check: null` is not a defect; it is a warning.

**Each `plugins[]` item.** Allowed keys: `name`, `marketplace`. Any other key is
a defect: `plugins[<i>].<key>: unknown key`.

- `name` and `marketplace` are both required strings matching `^[A-Za-z0-9_.-]+$`.

**Globs.** A glob is split on `/`. A segment that is exactly `**` matches any
number of path segments, including none. Within any other segment, `*` matches
any run of characters except `/`. Every other character is literal. A glob is
matched against the tracked file list only.

The validator reports every defect it finds, not only the first.

## The validator

```
node check-standards.js [--root <dir>] [--json] [<manifest>]
```

- `--root` is the repo root; it defaults to the current directory. `<manifest>`
  is resolved against the root; it defaults to `.claude/standards.json`.
- **Exit 0**: valid. With `--json`, stdout is the normalized manifest. Without
  it, stdout is empty.
- **Exit 2**: invalid, missing or unparsable, or an unrecognized argument.
  stderr carries one line per defect, shaped `standards: <manifest>: <defect>`.
  stdout is empty.
- **Warnings** go to stderr in either case, one line per rule with `check: null`,
  shaped `standards: <doc>: rule has no check`. A warning never changes the
  exit code.

**Normalized manifest.** Keys in the order shown in §The manifest
(`version, checks, rules, preamble, plugins`; `name, command`;
`doc, paths, check`; `name, marketplace`). An absent `preamble` is `null`, an
absent `plugins` is `[]`, and an absent rule `paths` is `null`. Array order is
kept. A normalized manifest is itself valid.

**Module.** Readers in the same process use the exports instead of the CLI:

- `validateStandards({ text, files })` → `{ ok, manifest, defects, warnings }`.
  Pure: `text` is the manifest's contents and `files` the tracked file list.
  `defects` are the `<defect>` strings above without the `standards: <manifest>: `
  prefix; `warnings` are `<doc>: rule has no check`. When `ok`, `manifest` is
  normalized; when not, it is the parsed object, or `null` if the text did not
  parse to an object.
- `validateFile(repoRoot, manifestPath = '.claude/standards.json')` reads the
  file and takes `files` from `git -C <repoRoot> ls-files`. Same result, plus
  `path`.
