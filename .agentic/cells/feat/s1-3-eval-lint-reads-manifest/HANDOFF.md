# HANDOFF: S1.3 — the eval runner's `lint` check runs the work directory's manifest

## Done

- `evals/tests/standards-check.test.js` committed first (522f4b0); against the pre-change tree it printed `--- 13 checks, 10 failed` (load rejected the command-less `lint` check: `needs command, resultMatches or resultNotMatches`).
- `evals/lib/cases.js`: a `lint` check with no `command`, `resultMatches` or `resultNotMatches` is valid; `tests` and `policy` are still rejected without one.
- `evals/lib/exec.js`: `runManifestChecks` reads `<workdir>/.claude/standards.json` and runs each `checks[].command` with `bash -c` in the work directory, in order, stopping at the first failure. Messages: `no .claude/standards.json in the work directory`; `.claude/standards.json is not valid JSON: <parse error>`; `<name> exited <n>: <command>`. Two further messages cover inputs the package does not name: `.claude/standards.json has no checks array` and `<name> has no command`. The validator is not imported.
- `evals/schema.json`: a fourth `anyOf` branch admits `kind: "lint"` with none of the three fields.
- `evals/README.md`: documents the command-less `lint` check and lists the new test; the stale "runs the first, not yet the second" sentence now reads "runs all three" (`scripts/test.sh:69` globs `evals/tests/*.test.js`).
- `evals/cases/contract-runs-standards-checks.json`: the case from the package, quoting §6 step 2. It loads under `scripts/tests/evals-cases.test.sh` (21 valid cases, 0 errors).

## Not done

- The new case has not been run against a real model; no eval suite run was in scope.

## Next

- Review and merge. A live eval run of `contract-runs-standards-checks` with `--contract` is the next observation of whether the contract makes a worker run the checks.

## Plan check

Package issue still matches: yes
