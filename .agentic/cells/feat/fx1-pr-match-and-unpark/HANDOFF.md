# HANDOFF: FX1

## Done
- `prFor` matches on exact head branch only (`plugins/fleet/src/reap.js:50`). Title and closing-keyword fallbacks removed.
- The `parked` branch of `reap` looks up the package PR with `prFor` before requesting an unpark. If one exists in any state, the session is closed with outcome `pr` and no launch request is made. `listPulls` already uses `--state all` (`plugins/fleet/src/tracker.js:34`).
- `plugins/fleet/tests/pr-match.test.sh` written first; it failed 6 of 11 checks against the pre-change tree, and passes 11 of 11 after.
- Changed `reap.test.sh` assertions (the fallback ones only): closing-keyword match and lower-case-id title match now expect `null`. No other assertion changed.
- `SKILL.md` and `README.md` describe branch-only matching and the no-unpark-with-PR rule.

## Next
- Nothing beyond review and merge.

## Plan check

Package issue still matches: yes
