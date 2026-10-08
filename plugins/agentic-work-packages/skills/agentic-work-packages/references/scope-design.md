# Designing allowedPaths and forbiddenPaths

Use this when cutting a package and deciding what goes in its `SCOPE.json`
lane. `scope-contract.md` defines the fields, the enforcement hook and the
worker protocol; this file covers how to choose the paths, with worked
path sets for common kinds of work and the failure patterns that show up in
review.

## Heuristics

1. **Narrow beats broad.** A clear boundary is easier for a worker to respect
   and easier for a reviewer to check.
2. **Name paths, not trees.** List the directories and files the package owns.
   A wildcard over a whole source root defeats the lane (see Failure patterns,
   below, for the one exception).
3. **Protect shared code.** The serialising categories in `scope-contract.md`
   §Choosing forbiddenPaths go in every package's `forbiddenPaths`, except the
   one package that owns them.
4. **Declare known blockers up front.** If the work needs a shared type, a
   migration or a config change, the package that makes it is a dependency
   from the start, not a surprise at the first `BLOCKER.md`.

## Path sets by kind of work

Each set shows `allowedPaths` for one kind of package. Substitute the repo's
real paths. Test paths are always included, per `scope-contract.md` §Choosing
allowedPaths.

### New feature

```json
"allowedPaths": [
  "src/features/<feature>/**",
  "test/features/<feature>/**"
]
```

Three questions decide whether this holds:

- **Does it touch more than one subsystem?** Then it is more than one package.
  See `cell.md` §Sizing. Do not widen `allowedPaths` across two subsystems to
  keep it as one.
- **Does it need a shared type or interface?** File a contract-change package
  first and put its branch in `dependsOn`. The feature package never edits the
  contract.
- **Does it need a config or manifest change?** Those paths stay in
  `forbiddenPaths`. If the change is required, it is a separate package or a
  `BLOCKER.md`, and it is better planned than discovered.

### Bug fix

A small fix names the files:

```json
"allowedPaths": [
  "src/components/<Component>.tsx",
  "test/components/<Component>.test.tsx"
]
```

A fix that spans several files names the directory:

```json
"allowedPaths": [
  "src/utils/<utility>/**",
  "test/utils/<utility>.test.ts"
]
```

If the fix requires a refactor, widen to the refactor area, and no further.
The regression fixture lives under the test path, so the path set must reach it.

### Refactor

```json
"allowedPaths": [
  "src/components/<Component>/**",
  "test/components/<Component>/**"
]
```

A refactor that changes a public API is a contract change. The package that
makes it is a `cell:contract-change` package, dispatched alone.

### Documentation

```json
"allowedPaths": ["docs/**"],
"forbiddenPaths": ["src/**", "test/**"]
```

Keep documentation-only packages separate from code packages. A package that
mixes the two has a lane that is wider than either half needs.

### Feature with subfolders and a hook file

```json
"allowedPaths": [
  "src/components/<Widget>/**",
  "src/hooks/use<Widget>Keyboard.ts",
  "test/components/<Widget>/**",
  "test/hooks/use<Widget>Keyboard.test.ts"
]
```

The `**` captures subfolders, and the related code and its tests sit in one
lane.

### Feature with several concerns

For a feature such as login, signup and password reset, there are two ways to
cut it:

- **One package**, if the concerns are related:
  `src/features/auth/**` and `test/features/auth/**`.
- **Three packages**, if they are independent: one under
  `src/features/auth/login/**`, one under `.../signup/**` and one under
  `.../password-reset/**`. The second and third declare `dependsOn` the first
  where they share its components.

Prefer the split when the concerns could run in parallel; the wave and WIP
rules are in `coordination.md` §Waves and the WIP cap.

### A utility shared by two features

Two shapes, depending on the utility's size:

- **Small:** one package owns the utility and both features' paths.

  ```json
  "allowedPaths": [
    "src/utils/<new-utility>.ts",
    "src/features/<feature-a>/**",
    "src/features/<feature-b>/**",
    "test/features/<feature-a>/**",
    "test/features/<feature-b>/**"
  ]
  ```

- **Substantial:** put it in the shared contract path through a
  contract-change package, and have both feature packages `dependsOn` it.

### Fixing a utility that lives in a contract path

A package cannot edit a contract path from a feature lane. Cut a
contract-change package:

```json
"feature": "contract-fix-<utility>",
"allowedPaths": ["contracts/**", "test/contracts/**"],
"forbiddenPaths": ["src/**"]
```

The consumer packages follow it through `dependsOn`. The contract package
still carries its own test path: the same rule applies to every lane.

## Concrete forbiddenPaths entries

`scope-contract.md` §Choosing forbiddenPaths names the categories. In a
typical JavaScript repo they expand to entries like these:

```json
"forbiddenPaths": [
  "contracts/**",
  "src/types/shared/**",
  "package.json",
  "package-lock.json",
  "yarn.lock",
  "tsconfig.json",
  "tsconfig.*.json",
  ".github/**",
  ".env*",
  "docker-compose.yml",
  "Dockerfile",
  ".husky/**",
  ".gitignore",
  "README.md",
  "LICENSE"
]
```

The environment, infrastructure, hook and repository-metadata entries go past
the categories in the contract: secrets, container and deploy files, git hooks
and root documents are not feature code, and none belongs in a feature lane.

Add these per repo where they exist and are shared:

```json
"src/index.ts",
"src/App.tsx",
"webpack.config.js",
"jest.config.js",
".env.example"
```

These are the entry point, the root component, build config, test config and
config documentation. Whether to forbid them depends on whether the package
legitimately touches them.

## Layout follows the repo

Paths must match where the code actually lives, so read the tree before writing
them. Two consequences:

- A repo whose code sits under a subdirectory uses that prefix throughout, for
  example `native/src/**`, `native/include/**` and `native/test/**`.
- Where a package is the whole of one small repo and the repo boundary already
  contains it, a broad `src/**` can be the right granularity, because the
  repo, not the glob, provides the containment. The condition is that the
  package really does own the repo's source. In a repo shared by several
  packages, the broad glob is the failure below.

## Failure patterns

### Too-broad `allowedPaths`

```json
"allowedPaths": ["src/**"]
```

Every file under the source root is writable, so the lane no longer separates
this package from any other. Name the feature's directory:

```json
"allowedPaths": ["src/features/<feature>/**"]
```

### An empty or thin `forbiddenPaths`

```json
{
  "allowedPaths": ["src/components/**"],
  "forbiddenPaths": []
}
```

Nothing stops the worker from editing a shared type, which breaks every package
that depends on it. Narrow the allow and add the serialising paths:

```json
{
  "allowedPaths": ["src/components/<Feature>/**"],
  "forbiddenPaths": [
    "contracts/**",
    "src/types/shared/**",
    "package.json",
    "tsconfig.json"
  ]
}
```

### A needed contract change that the package does not mention

```json
{
  "feature": "new-api-integration",
  "allowedPaths": ["src/services/api/**"],
  "dependsOn": []
}
```

If the integration needs a new type in a contract path, the worker hits a
blocker on the first edit. That was foreseeable, so plan it:

```json
{
  "feature": "new-api-integration",
  "allowedPaths": ["src/services/api/**", "test/services/api/**"],
  "dependsOn": ["contract/new-api-types"]
}
```

Keep the issue's `Depends on` line in step with `dependsOn`, as `SKILL.md`
requires.

### Unrelated changes in one lane

```json
{
  "feature": "big-refactor",
  "allowedPaths": ["src/components/**", "src/utils/**", "src/services/**"]
}
```

A lane that wide invites unrelated edits and cannot be reviewed against one
purpose. Split it into one package per area, with `dependsOn` between them
where they share code.

## Design check

Before filing a package, confirm what is not already covered by
`SKILL.md` §Pre-dispatch checklist:

- Each `allowedPaths` entry names a directory or file the package owns, and
  none spans two subsystems.
- For each path pattern, you can name one file it should allow and one it
  should deny.
- Known contract, migration, manifest or config needs appear as `dependsOn`
  entries, not as expected blockers.

When a live package turns out to have the wrong lane, the worker stops and
files `BLOCKER.md`, and the fix is a coordinator decision. See
`scope-contract.md` §Worker protocol.
