# Agent teams within a package

Use this when a worker considers spawning subagents or teammates inside one
package, to parallelize work within its lane. Packages and agent teams solve
different coordination problems, and the two combine: a worker may use a team
internally without changing the package boundary.

- **Packages** coordinate across branches, repos and sessions: one package, one
  branch, one worker, one `SCOPE.json`, one PR. The coordinator manages the
  boundaries between them.
- **Agent teams** parallelize within a session: several subagents inside one
  package, working on different subtasks at once.

`coordination.md` §Two levels of fan-out states the rule: the lane is
inherited, and the sub-fan-out does not widen it. The `implement+review` and
`implement+test` values of `execution.pattern` in `scope-contract.md` name the
two most common team shapes.

## When a team helps

A team fits when the package has independent subtasks that can run at the same
time:

- **Implementation and testing:** one teammate writes code while another writes
  tests for components that are already done.
- **Multi-file scaffolding:** independent source files created in parallel.
- **Research and implementation:** one teammate explores the codebase while
  another starts on a well-understood part.

## When a team does not help

- The package's work is inherently sequential, each step depending on the last.
- The scope is narrow enough that parallelism adds overhead and no benefit.
- The subtasks touch overlapping files, which risks conflicts.

## Scope enforcement

Every teammate works under the same `SCOPE.json` and the same `allowedPaths`
and `forbiddenPaths` as the worker that spawned it. The enforcement hook
judges `Edit` and `Write` calls against that lane; it does not distinguish
which teammate made them. The hook's residue, including writes through shell
commands, applies to teammates in the same way. See `scope-contract.md`
§Enforcement.

## Example

A worker on an `acme-api` package that adds a calculation integration spawns two
teammates:

1. **Implementer:** writes the integration in `src/`.
2. **Tester:** writes test cases in `test/`, based on the API shape recorded in
   the upstream package's `HANDOFF.md`.

Both are confined to the package's `allowedPaths`. The tester can begin test
stubs and fixtures while the implementer works on the integration.

## Declaring it

Declare the pattern in the package's `execution` block (`pattern`, and `agents`
where the repo defines named agent types) so the plan records what the package
was expected to use. The existing `SCOPE.json` and hook already handle
enforcement, so no further configuration is needed for scope. See
`scope-contract.md` §The `execution` profile.

## Limitations

- A team exists within one session and does not persist across sessions.
  Whatever it learns must reach `HANDOFF.md` (`context-management.md`).
- Teammates share the worker's context window, so a large codebase leaves less
  room for parallel context.
- A teammate's report that tests pass is a pointer to re-query, not a
  clearance. The stamp comes from a run that could have failed
  (`working-agreements.md` §Evidence is stamped to a sha).
- Teammates cannot communicate with workers on other packages. Cross-package
  coordination goes through the coordinator, by `BLOCKER.md` and `HANDOFF.md`.
