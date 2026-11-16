# HANDOFF: H0.5 the other seven fleet suites wait for the stub's files

## Done
Waits added before every positive read of a stub-written file after a launch, using
`wait_for_file` / `wait_for_count` from `plugins/fleet/tests/lib.sh` (H0.4). No
assertion was changed or removed; `lib.sh` and the stubs are untouched.

- `ci-preconditions.test.sh`: H, wait for `T1.1.*.argv` before the argv read
- `instructions-leak.test.sh`: E and F, wait for `T1.5.*.argv` and `T1.6.*.argv`
- `verify-config.test.sh`: C, wait for `V1.1.*.argv` and `V1.2.*.argv`
- `verify-stage.test.sh`: fail, wait for `T1.2.2.argv` before `assert_file` and the read
- `v4-gate.test.sh`: 2, `wait_for_count "$TMP/claude-log" '*.argv' 2` before `started`
- `cycle.test.sh`: B, wait for `T1.1.1.argv` and `T1.1.1.env` (the stub writes .env after .argv)
- `integration-branch.test.sh`: E, wait for `T1.1.*.argv`

Each "no worker started" read keeps its immediate read and now has a comment saying
why: ci-preconditions F, instructions-leak A, v4-gate 1, integration-branch C,
verify-stage cap, cycle D (T1.1.2/T1.4.2), E (T1.3.3), E2 (T1.4.2 twice), H.

Reads already behind a `wait_exit` were left alone: cycle `T1.3.2.argv` (after
`wait_exit 12-2`) and `T1.4.2.argv` (after `wait_exit 13-2`). The stub writes its argv
before it exits.

## Not verified by me
This session denies every command that sets an environment variable, so the
`CLAUDE_STUB_DELAY=3` before-and-after runs (acceptance criterion 1) were not done.
A person needs to run, at `182b172` (before) and at the branch head (after):

    CLAUDE_STUB_DELAY=3 bash plugins/fleet/tests/<suite>.test.sh

for ci-preconditions, instructions-leak, verify-config, verify-stage, v4-gate, cycle
and integration-branch. Expected: each fails before and passes after.

## Next
- Reviewer: run the delay check above.

## Plan check

Package issue still matches: yes
