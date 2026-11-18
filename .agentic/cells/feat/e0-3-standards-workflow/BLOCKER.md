# BLOCKER: E0.3 — the runner cannot run alone; its validator has no installed path in this lane

**Bucket:** on a decision
**Kind:** human-decision
**Reference:** #222 (E0.3), epic #219 (E-D1)
**Owner:** coordinator / Ken
**Un-blocks when:** #222 records which option below applies, and `SCOPE.json` is re-cut to match if needed

## What was needed, and why

E0.3 installs two files per repo: the workflow and `.github/standards/run-checks.js`,
a byte-identical copy of `assets/scripts/run-checks.js`. On `pull_request` the
workflow copies the base branch's runner to `$RUNNER_TEMP/run-checks.js` and runs it.

The runner is not self-contained.
`plugins/agentic-work-packages/skills/agentic-work-packages/assets/scripts/run-checks.js:35`:

```js
const { validateStandards, validateFile } = require(path.join(__dirname, 'check-standards.js'));
```

So:

- `.github/standards/run-checks.js` requires `.github/standards/check-standards.js`,
  which nothing installs.
- `$RUNNER_TEMP/run-checks.js` requires `$RUNNER_TEMP/check-standards.js`, which
  the scoped `git show` step does not copy.

Either way node throws `MODULE_NOT_FOUND` before any check runs, so the
`standards` job cannot pass. That fails the first acceptance criterion. I read
the code path; I could not run a probe (shell writes to a temp dir were denied
in this session).

`.github/standards/check-standards.js` is not in `allowedPaths`.
`assets/scripts/**` is in `forbiddenPaths`, which rules out making the runner
self-contained.

## Alternatives searched

- Run the runner from the plugin path (`plugins/.../assets/scripts/run-checks.js`):
  that path exists only in this repo, and E-D1 says each repo runs its own
  committed copy. The workflow asset would not be generic.
- Set `NODE_PATH` or use a symlink: the require is an absolute `__dirname` join,
  so module resolution is never consulted.
- Have the workflow fetch `check-standards.js` from `nodots/nodots-orchestrator`:
  this breaks E-D1 and the "never checks out another repository" criterion.
- Have the workflow copy the base's `assets/scripts/check-standards.js` next to
  the runner: that works only in this repo.

## The ask

E0.3-B1: How does the committed runner get its validator?
(a) A repo commits three files, adding `.github/standards/check-standards.js`
as a byte-identical copy of `assets/scripts/check-standards.js`. The workflow
copies both base-branch files into `$RUNNER_TEMP`, and the copy check covers
all three. This needs `.github/standards/check-standards.js` added to
`allowedPaths`, and the issue's "two files" changed to three.
(b) A follow-up package makes `run-checks.js` self-contained by bundling the
validator, and E0.3 waits on it. This touches `assets/scripts/**` and duplicates
the validator.
: Recommend (a). It keeps one validator (`references/standards.md:44`, "none
parses the manifest on its own"), it needs no change to E0.2's script, and the
base-branch copy still means a PR cannot change the code that judges it.
: decide-by the next coordinator cycle
: cost-of-waiting: E0.3, and E0.4 (#223) behind it, stall. No CI runs the
standards checks on any PR.
