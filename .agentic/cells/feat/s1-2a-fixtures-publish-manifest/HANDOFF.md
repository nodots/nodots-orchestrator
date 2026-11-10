# HANDOFF: S1.2a — Fleet fixture repos publish a valid standards manifest

## Done
- `plugins/fleet/tests/fixture-standards.test.sh` (new, committed first as a failing test in 238e332: 15 of 17 checks failed against the pre-change tree). It builds a README-only repo, calls `fixture_standards`, asserts `check-standards.js --root <repo>` exits 0 with no stderr, the tree is clean, the commit adds only `.claude/standards.json` with message `fixture: standards manifest`, the helper is silent, and it exits non-zero outside a git repo. It also greps each of the ten suites for a `fixture_standards` call.
- `plugins/fleet/tests/lib.sh`: `fixture_standards <clone dir>` writes `{"version": 1, "checks": [{"name": "test", "command": "true"}], "rules": []}` and commits it. The caller pushes.
- Each of the ten suites gets one added line directly after its `commit -qm init && ... push -q -u origin main` line: `fixture_standards "<clone>" && git -C "<clone>" push -q origin main`. The init line is unchanged, so the push comes on a new line rather than being split from it. `verify-config.test.sh` builds two clones (api, web) in a loop, so the call sits inside the loop and covers both. In `cycle.test.sh` the call comes before `feat/t1-0-base` is branched, so that base branch carries the manifest too.
- `git diff` on the ten suites shows only additions (one line each). No assertion changed.
- `bash scripts/test.sh` ends `ALL PASS` (see the VERIFIED comment on the PR).

## Next
- S1.2 (#125) can make the manifest a launch precondition without editing these suites.

## For a cold session
- Nothing is pending in this package. To check it again, run `bash scripts/test.sh`. It takes about 10 minutes.

## Plan check

Package issue still matches: yes
