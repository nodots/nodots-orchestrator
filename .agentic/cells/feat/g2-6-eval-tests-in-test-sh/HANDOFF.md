# HANDOFF: G2.6 (issue #91)

## Done
- `scripts/test.sh`: new "eval tests" section runs each `evals/tests/*.test.js` and `evals/gates/*.test.js` with `node`, prints `PASS`/`FAIL` with the tally, sets non-zero status on failure. Each of the two globs fails separately when it matches nothing.
- `scripts/tests/test-sh.test.sh`: fixture gains eval files; 10 new checks (pass, failing, throwing, empty glob in each dir). Written first: 10 of 22 failed before the change, 0 of 22 after.
- `CLAUDE.md`: test command description and healthy-output tail updated.
- Neither eval test calls a model: `contract-option.test.js` uses `evals/tests/stubs/claude.sh` (`evals/tests/contract-option.test.js:5,18`); `v2-degraded-contract.test.js` spawns nothing.
- Both files print `--- N checks, M failed` and set `process.exitCode = 1` on failure (`contract-option.test.js:85-86`, `v2-degraded-contract.test.js:60-61`).

## Verified
`bash scripts/test.sh` ends with `PASS evals/tests/contract-option.test.js --- 13 checks`, `PASS evals/gates/v2-degraded-contract.test.js --- 15 checks`, `ALL PASS`.

## Next
Nothing for this package. The full run takes more than 120 seconds, so use a long timeout.

## Plan check

Package issue still matches: yes
