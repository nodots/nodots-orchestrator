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
  "plugins": [ { "name": "<plugin>", "marketplace": "<marketplace>" } ],
  "review": { "passes": 2 }
}
```

The commands are placeholders: a command is whatever the repo runs, and the
orchestrator names no toolchain.

- **The repo owns it.** A change to a standard is a PR in that repo. The orchestrator reads it and never writes it, except through `fleet standards init`, which drafts to disk for a human to commit.
- **No manifest, no launch.** The launcher refuses a target whose default branch has no valid manifest, as it refuses one with CI disabled. `targets[].standards: "off"` is the one, explicit, reported exception; there is no convention fallback.
- **Checks are commands; rules are pointers.** A `check` is run and quoted in the stamp. A `rule` names the document to read, the paths it applies to, and the check that enforces it; a rule with `check: null` is allowed and reported as a warning.
- **Rules are lane-scoped.** A worker is briefed only on rules whose `paths` overlap its `allowedPaths`, plus rules with no `paths`.
- **The preamble is the repo's.** The hook prints the file the manifest names; the orchestrator ships no preamble text.
- **The review policy is the repo's.** `review` says how many independent reviews a PR needs at its head (`passes`), counted from `REVIEWED` stamps, one per distinct reviewer (`references/working-agreements.md` §Evidence is stamped to a sha). A verified PR short of the policy is `cell:awaiting-reviewer`, not `cell:awaiting-review`. A repo without the key needs no reviews, and its PRs move as before.

## Readers

Every reader validates through `check-standards.js`; none parses the manifest on its own.

| Reader | What it takes from the manifest |
|---|---|
| Worker contract §6 | The checks to run and quote in the `VERIFIED` stamp, and the rules to read |
| Launcher (`fleet cycle`) | Refuses a target with no valid manifest; briefs the worker on every check and on the rules whose `paths` overlap its lane |
| Preamble hook (SessionStart) | Prints the file `preamble` names |
| Eval runner | The checks a `lint` case runs in the work directory |
| Label sync (`sync-cells.sh`) | The `review` policy, read from the default branch, which holds a verified PR at `cell:awaiting-reviewer` until it is met. It judges the key with `validateReview`, since it has no tracked file list |
| Standards workflow (`standards-checks.yml`) | On a pull request, the runner and validator from the **base** branch run the checks against the PR's merge commit (what `actions/checkout` checks out on `pull_request`); on a push, the tree's own copies |

## Running the checks in CI

A repo commits three files, each byte-identical to its asset under
`assets/` in this plugin:

| Installed | Source |
|---|---|
| `.github/workflows/standards-checks.yml` | `assets/workflows/standards-checks.yml` |
| `.github/standards/run-checks.js` | `assets/scripts/run-checks.js` |
| `.github/standards/check-standards.js` | `assets/scripts/check-standards.js` |

The runner loads the validator from its own directory, so both are copied side
by side. The job needs `contents: read` and nothing else, and it never checks
out another repository: CI runs the repo's own copy, in the repo with the code.

On `pull_request` the job copies both scripts out of the base branch
(`git show origin/<base>:.github/standards/<file>`) into `$RUNNER_TEMP`, so a PR
cannot change the runner or the validator that judges it. A base branch missing
either file fails the job, naming it. The checks run against the PR's merge
commit, the ref `actions/checkout` fetches on `pull_request`, not the head
branch alone. On `push` the job runs the tree's own copies with `--base HEAD`.
The branch gate is a job-level `if:`, so a push to any other branch skips the
whole job rather than passing it vacuously, and the push run is named
`standards (push)`: only the `pull_request` run reports `standards`, the check
to require. The job runs on a push only when `github.ref_name` equals the repo variable `STANDARDS_BRANCH`, or,
when that variable is unset, the repo's default branch
(`github.event.repository.default_branch`). No branch name is written in the
file, so a repo whose default branch is `main` or `development` commits it
unedited; set `STANDARDS_BRANCH` to follow a different branch.

**Copy check.** `scripts/test.sh` fails when an installed copy differs from its
asset or is missing, naming the file, as it does for the hooks.

**Residue.** The base-branch runner does not cover:

- a PR that changes a script a check calls (E-D2);
- a PR that changes the workflow file itself.

Branch protection or a ruleset that requires the `standards` status check, with
review required on `.github/**`, covers the second.

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

**Top level.** Allowed keys: `version`, `checks`, `rules`, `preamble`, `plugins`,
`review`. Any other key is a defect: `<key>: unknown key`.

- `version` is the integer `1`.
- `checks` is a non-empty array of objects.
- `rules` is an array of objects. It may be empty.
- `preamble`, when present and not `null`, is a string naming a tracked file.
  `null` is the same as absent.
- `plugins`, when present, is an array of objects. It may be empty.
- `review`, when present and not `null`, is an object. `null` is the same as
  absent. Otherwise: `review: must be null or an object with one integer key,
  passes`.

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
- The plugin is enabled in the repo's tracked `.claude/settings.json`:
  `enabledPlugins["<name>@<marketplace>"]` is present and exactly `true`.
  Absent, `false`, any other value, a key under another marketplace, or a
  settings file that is missing or untracked is the defect
  `plugins[<i>]: <name>@<marketplace> is not enabled in .claude/settings.json`.
  A settings file that is not JSON is the one defect
  `.claude/settings.json: not valid JSON: <parser message>`, and one that is not
  a JSON object is `.claude/settings.json: not a JSON object`. An item whose
  `name` or `marketplace` is malformed has that defect only.

**The `review` object.** Allowed key: `passes`. Any other key is a defect:
`review.<key>: unknown key`.

- `passes` is a required integer, at least `1`. Otherwise:
  `review.passes: must be an integer >= 1`, or `review.passes: <n> must be >= 1`.

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
- `.claude/settings.json` is read, from the root, only when `plugins[]` is
  non-empty, and only when it is a tracked file. A copy on disk that is not
  tracked is not read.
- **Exit 0**: valid. With `--json`, stdout is the normalized manifest. Without
  it, stdout is empty.
- **Exit 2**: invalid, missing or unparsable, or an unrecognized argument.
  stderr carries one line per defect, shaped `standards: <manifest>: <defect>`.
  stdout is empty.
- **Warnings** go to stderr in either case, one line per rule with `check: null`,
  shaped `standards: <doc>: rule has no check`. A warning never changes the
  exit code.

**Normalized manifest.** Keys in the order shown in §The manifest
(`version, checks, rules, preamble, plugins, review`; `name, command`;
`doc, paths, check`; `name, marketplace`; `passes`). An absent
`preamble` is `null`, an absent `plugins` is `[]`, an absent rule `paths` is
`null`, and an absent `review` is `null`. Array order is kept. A normalized
manifest is itself valid.

**Module.** Readers in the same process use the exports instead of the CLI:

- `validateStandards({ text, files, settings })` → `{ ok, manifest, defects, warnings }`.
  Pure: `text` is the manifest's contents and `files` the tracked file list.
  `settings` is optional: the text of `.claude/settings.json`, or `null` when
  that file is not tracked. When it is `undefined`, the plugin enablement check
  is skipped, so a caller that passes only `text` and `files` gets the result it
  got before the check existed.
  `defects` are the `<defect>` strings above without the `standards: <manifest>: `
  prefix; `warnings` are `<doc>: rule has no check`. When `ok`, `manifest` is
  normalized; when not, it is the parsed object, or `null` if the text did not
  parse to an object.
- `validateFile(repoRoot, manifestPath = '.claude/standards.json')` reads the
  file and takes `files` from `git -C <repoRoot> ls-files`. When `plugins[]` is
  non-empty, it passes the text of `.claude/settings.json` if that file is
  tracked, and `null` if not; otherwise it does not read the file. Same result,
  plus `path`.
- `validateReview(review)` → the `review` defects above, for the value of the
  `review` key alone. `null` has none. For a reader with no tracked file list.
