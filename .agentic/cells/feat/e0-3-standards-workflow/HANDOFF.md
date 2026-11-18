# HANDOFF: E0.3 — the standards workflow and runner

## Coordinator decision E0.3-B1 (2026-11-17)

Recorded in the #219 decisions log; #222 re-cut to match.

- Option (a): each repo commits three files — the workflow, `.github/standards/run-checks.js` and `.github/standards/check-standards.js`, each byte-identical to its asset under `assets/`.
- On `pull_request` the workflow copies both scripts from the base branch into `$RUNNER_TEMP`; a base branch missing either fails, naming it.
- The copy check in `scripts/test.sh` covers all three installed copies.
- `SCOPE.json`: `.github/standards/check-standards.js` added to `allowedPaths`. `assets/scripts/**` stays forbidden.
- Option (b), bundling the validator into the runner, is dropped.

Next: implement #222 as re-cut. Tests first.
