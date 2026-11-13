# HANDOFF: SV1 — standards gate (Phase 1)

## Done
- `plugins/fleet/tests/sv1-standards-gate.test.sh` (46 checks), modeled on
  `plugins/fleet/tests/ci-preconditions.test.sh`. Five phases, each with its own
  package id, state, worktrees and claude log:
  1. Fixture clone with `package.json` (test, lint, start) and `CLAUDE.md`;
     `fleet standards init --target acme/api --write` drafts lint, test and the
     CLAUDE.md rule; `check-standards.js` accepts it; commit and push; the dry run
     launches with `{"checks":["lint","test"],"rules":1,"applicable":1}` and the
     report line `standards: lint, test (1 of 1 rules in lane)`.
  2. Applied cycle with the claude stub: the prompt carries each drafted
     `name: command` read from the written file, and
     `CLAUDE.md (all paths)`.
  3. Manifest removed on main: applied cycle alarms `launch-standards-missing`,
     no worktree, no worker, no branch pushed; the text report lists the alarm.
  4. Manifest with an unknown key `reviewers`: `launch-standards-invalid`
     naming `reviewers: unknown key`.
  5. `"standards": "off"`: launched, row and report say off, prompt has no
     standards, rules or no-rule line.
- `evals/gates/sv1-standards.test.js` (17 checks), modeled on
  `evals/gates/v2-degraded-contract.test.js`: copies
  `evals/cases/contract-runs-standards-checks.json` into a temp cases dir, loads
  it, runs `evals/run.js` under `evals/tests/stubs/claude.sh` with the work dir
  prepared as the prompt describes. The command-less lint check passes; a
  control with `lint.sh` exiting 1 fails `lint exited 1: bash lint.sh`; with the
  manifest removed it fails `no .claude/standards.json in the work directory`.

## Findings
- Reusing one package id across phases makes the label sync read the package
  as active from the earlier phase's pushed branch, so a refusal is never
  reached. The test uses T1.1 to T1.5 for that reason.
- Under the stub the case as a whole fails (the stub does not run `lint.sh`, so
  `test -s .standards-ran` fails). The gate asserts on the lint check's own
  result in `results.json`, as the issue scopes it.
- No mutation of product code was run to show the gates can fail: `plugins/fleet/src/**`
  and `evals/lib/**` are forbidden in this lane. The eval gate carries a
  failing control (its section 3); the first fleet run failed 10 checks on fixture
  errors before the per-phase ids were introduced.

## Next
- Review and merge. Phase 2 (#128) is gated on this.

## Plan check

Package issue still matches: yes
