# BLOCKER: S1.2 — a required-by-default manifest refuses every existing fleet fixture launch, and those suites must pass unchanged

**Bucket:** blocked on a decision
**Kind:** human-decision
**Reference:** #125 (scope of work, bullet 1; acceptance criterion 5), epic #117 (DoD "Existing fleet, plugin and eval suites pass unchanged")
**Owner:** coordinator
**Un-blocks when:** #125 is edited to say how the existing fleet fixture suites get past the new launch check, and the lane includes whatever that answer needs

## What was needed, and why

#125 makes `targets[].standards` default to `{ "manifest": ".claude/standards.json" }`. It also requires `launch()` to refuse with `standards-missing` when that path does not exist on `origin/<defaultBranch>`. The refusal comes after the CI checks (`plugins/fleet/src/launch.js:205`) and before the dry-run return (`:209`), so dry runs are refused as well.

The existing fleet suites build their target repo with only a `README.md` and give no `standards` field:

- `plugins/fleet/tests/ci-preconditions.test.sh:27-28` (clone holds `README.md` only), config at `:58-69` (no `standards`); case A at `:85-86` expects packages 10 and 12 to launch.
- `plugins/fleet/tests/cycle.test.sh:30-31`, config at `:77`; launches are asserted at `:165-166`, among others.
- `plugins/fleet/tests/verify-config.test.sh:24-25`, config at `:60-61`; launches are read at `:98`.
- These suites also configure a `localPath` target and launch: `adoption`, `v4-gate`, `verify-manual`, `daemon`, `vanished`, `epic-scope` and `verify-stage` (`*.test.sh`).
- `grep -n standards plugins/fleet/tests/*.test.sh` prints nothing.

With the default from #125, every one of these launches is refused `standards-missing`. That breaks acceptance criterion 5 ("`ci-preconditions.test.sh`, `verify-config.test.sh` and `cycle.test.sh` pass unchanged") and criterion 6 (`bash scripts/test.sh` ends `ALL PASS`). Editing those test files is outside `allowedPaths`. The only test file in the lane is `plugins/fleet/tests/standards-launch.test.sh`.

I made no code change. I reached this conclusion by reading the code at the lines above. I did not run the suites against an implementation.

## Alternatives searched

- Default `standards` to `"off"` when absent: this contradicts #125 and the epic decision "No manifest, no launch … `"off"` is the one, explicit, reported exception" (#117, Decisions log 2026-11-04, "No convention fallback").
- Skip the check when `FLEET_TEST_HOOKS=1` (the seam `launch.js:28` uses): the existing suites would then never exercise the real launch path. A test-only bypass also hides the check, which the contract's no-fallback rule forbids (§4). The package does not ask for it.
- Have `launch()` treat a fixture repo, for example a missing remote, as exempt: this is a guessed fallback, and the same objection applies.
- Add `.claude/standards.json` or `"standards": "off"` to each existing fixture: this means editing ten test files outside `allowedPaths`, and criterion 5 says they stay unchanged.
- Put the manifest into the shared fixture setup (`plugins/fleet/tests/lib.sh` or `stubs/`): both are outside `allowedPaths`, and each suite builds its own repo inline, so a shared file would not reach the clones anyway.

## The ask

S1.2-D1: How do the existing fleet fixture suites pass once a manifest is required by default? Options:
(a) Widen the S1.2 lane to the ten fixture suites listed above, and drop "unchanged" from criterion 5. Each fixture repo then commits a valid `.claude/standards.json`, which exercises the real path.
(b) Widen the lane to the same suites, and have each fixture config set `"standards": "off"`. This is smaller, but the suites stop covering the default.
(c) Cut a separate package, ordered before S1.2, that adds a manifest to every fixture repo. S1.2 then depends on it.

Recommendation: (c), or (a) if one package is preferred. Both keep the default under test and keep "no manifest, no launch" true. (b) leaves most launch tests running in the exception mode.

Decide by: before S1.2 is relaunched.
Cost of waiting: S1.2 stalls, and SV1 (#127) stalls with it, because it depends on S1.2.
