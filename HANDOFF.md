# HANDOFF: G3.1 metrics collector

## Done

- `scripts/metrics.js --repo <owner/name> [--last N] [--state-dir <dir>] [--pr-limit N] [--json]`. Reads via `gh` (`GH_BIN` overrides, as `plugins/fleet/src/config.js:110`). Every value line ends in `[measured]`, `[estimated]` or `[unknown]`; the reason for an unknown is a `# ` note line.
- `scripts/tests/metrics.test.sh`, 22 checks, written first and run red (19 of 22 failed with the collector absent), then green. It uses `plugins/fleet/tests/stubs/gh.js` unchanged through `GH_BIN`.
- `bash scripts/test.sh` ends `ALL PASS`.
- Smoke run against real gh, `--last 5` on this repo: first-pass 5 of 5, stamp currency 5 of 5, hours open to merge 4.2 (measured), cost unknown (no state dir). So real gh returns `comments` as `{body}` objects and `issue view --json createdAt` works.

## Exploration: what each source exposes

| Metric | Source | Status |
|---|---|---|
| PRs per package | `gh pr list --state all --json number,title,body,state,createdAt,mergedAt`; package = issue named by `Closes #N` in the PR body (`plugins/fleet/src/launch.js:60` tells workers to write it) | computed, measured |
| First-pass merge rate | same PR list; first PR by `createdAt` for the package is MERGED | computed, measured |
| Stamp currency | PR `headRefOid` + `comments`, judged by `currentStamp` from `plugins/agentic-work-packages/skills/agentic-work-packages/assets/scripts/stamp.js:9` (same definition as `scripts/check-stamp.js`) | computed, measured |
| Hours issue open to merge | `gh issue view N --json createdAt` and PR `mergedAt` | computed, measured with real gh |
| Cost per merged package | `<stateDir>/logs/<issue>-<attempt>.log` (`plugins/fleet/src/store.js:103`), `total_cost_usd` on the `type:"result"` line of `claude -p --output-format json` (`launch.js:68`) | computed only when `--state-dir` is given |

## Not computable, and why

- **Hours open to merge in the fixture test.** The fleet gh stub strips `createdAt` from `issue view` (`plugins/fleet/tests/stubs/gh.js:45`) and I may not edit it. The CLI path therefore prints unknown in the test; the measured path is covered by calling `compute()` directly, and by the real-gh smoke run above.
- **Cost without `--state-dir`.** Unknown. Nothing in the tracker records cost.
- **Cost for a package with no fleet log**, such as one worked outside the fleet, or whose log has no result line (worker killed). Unknown for that package, not zero.
- **Cost of a package with a gap in attempt numbers** (for example logs 1 and 3, no 2). Labeled estimated: a lower bound.
- **Cost per merged package for the real fleet.** I did not find a real fleet log on this machine. `total_cost_usd` as the field name is confirmed only by the fleet claude stub (`plugins/fleet/tests/stubs/claude.sh:19`) and my recollection of the CLI, not by a real log. Check one real `<stateDir>/logs/*.log` before trusting the cost lines.
- **PRs without `Closes #N`.** Not attributed to any package. The smoke run skipped 29 of them, so rates cover only linked packages.
- **Window.** `--pr-limit` (default 200) bounds how many recent PRs are read; an older failed PR of a package can fall outside it and make first-pass look better than it was.

## Decisions to confirm

- A cost recorded in a log is labeled `measured` as the CLI's reported figure, not an invoice. If that should be `estimated`, the change is in `packageCost` (`scripts/metrics.js`).
- A total or mean with any package missing or estimated is `estimated` (`rollupLabel`), with coverage printed ("2 of 3 packages have log cost").

## Next

Nothing queued. Not in scope here: wiring `metrics.js` into `scripts/test.sh` syntax check (it only scans `plugins/`) or into the fleet report.

## Plan check

Package issue still matches: yes
