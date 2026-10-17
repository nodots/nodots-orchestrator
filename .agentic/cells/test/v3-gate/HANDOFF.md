# HANDOFF: V3 gate, the report is sourced (#41)

## Done

`scripts/tests/v3-gate.test.sh` (new, the only file in the lane). It runs inside `bash scripts/test.sh` on stub data (`plugins/fleet/tests/stubs/gh.js`).

- **Cited source.** The checker holds a `SOURCES` table: each metric key mapped to the gh field or fleet log it is read from, with `scripts/metrics.js` line numbers. A report that holds a metric with no entry fails, so a new metric cannot ship unsourced.
- **Label rule.** Every metric and every per-package cost is `measured`, `estimated` or `unknown`. An `unknown` has `value: null`, displays `unknown` and carries a note saying why.
- **Zero rule.** A zero metric must show a count of at least one behind it (`of N`, N ≥ 1). A per-package zero cost must be measured or estimated, which means a log line recorded 0.
- **Tracing.** Each metric moves when its stub source moves: PR state for first-pass rate, an extra PR for PRs per package, a VERIFIED comment for stamp currency, a log value for cost. When the source is removed, the metric turns unknown rather than zero (no READY PR, no merged package, no fleet log, a log with no result line).
- **Hours open to merge.** Traced through `compute()`, because the stub's `issue view` returns no `createdAt` (`plugins/fleet/tests/stubs/gh.js:41-44`).
- **Seeded defects.** The checker is shown to catch six mutated reports: a metric with no source, an uncounted zero, an unknown that carries 0, a missing label, an unknown with no note, and a dropped metric.
- **Real-run mode.** `bash scripts/tests/v3-gate.test.sh --repo <owner/name> [--state-dir <dir>]` applies the same checker to `metrics.js --last 10` against the real tracker and prints each metric with its source. I used arguments rather than env vars because worker permissions deny env-prefixed commands.

## Real run (2026-10-12, nodots/nodots-orchestrator, --last 10)

All 6 metrics passed the checker. Four were measured with sources: first-pass 100.0% (10 of 10), PRs per package 1.00, stamp currency 100.0% (10 of 10), hours open to merge 5.3 (10 of 10). Cost total and cost per package are `unknown`, with the note "no --state-dir given". The fleet state dir sits outside this worktree, and listing it was denied, so no fleet log was read. The collector also noted 33 PRs with no `Closes #N`, which are not attributed to any package.

## Interpretation to confirm

`metrics.js` does not print a source per metric; its output carries a label, a display with counts, and a note for unknowns. Under this gate, the source citation lives in the gate's `SOURCES` table and is proven by perturbation, not printed by the collector. If the owner wants each metric line to name its source, that is a change to `scripts/metrics.js`, which this lane forbids, and it needs a new package.

## Next

The Phase 3 close. A real run with `--state-dir` pointed at the fleet state dir would replace the two unknown cost values with log-backed figures.

## Plan check

Package issue still matches: yes
