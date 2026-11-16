# HANDOFF: H0.4 fleet fixture suites wait for the stub's files

## Done
- `plugins/fleet/tests/stubs/claude.sh`: `CLAUDE_STUB_DELAY` (seconds, default 0) sleeps after `mkdir -p "$LOG"` and before the argv file's number is picked and written.
- `plugins/fleet/tests/lib.sh`: `wait_for_file <path-or-glob> [timeout_s=15]` and `wait_for_count <dir> <glob> <n> [timeout_s=15]`. Both poll every 0.1 s and return 1 on timeout. `wait_for_count` waits for at least `<n>`, so a surplus still fails the exact-count assertion that follows.
- Waits were added before every positive read of a stub file in the four lane suites. No assertion was changed or removed:
  - `adoption.test.sh`: A "and starts one worker" (count 1), B's read of `T1.2.1.argv`, B "and starts a worker" (count 2)
  - `standards-isolation.test.sh`: H and I argv reads
  - `standards-launch.test.sh`: G argv read
  - `sv1-standards-gate.test.sh`: 2 and 5 argv reads
- Negative reads ("no worker was started") still read at once, and each has a comment. The launch is refused before the spawn, so no stub exists that could write later.
- Out-of-lane suites with the same race are listed in `BLOCKER.md` in this directory.

## Not verified by me
- The `CLAUDE_STUB_DELAY=3` before-and-after runs in acceptance criterion 1 were not done. This session denied every command with an environment-variable prefix, because it requires approval and nobody was there to give it. A person needs to run each command below twice: first at this branch's first commit, which adds only the stub delay, and then at the branch head:
  `CLAUDE_STUB_DELAY=3 bash plugins/fleet/tests/<suite>.test.sh` for adoption, standards-isolation, standards-launch and sv1-standards-gate.

## Next
- Coordinator: decide H0.4-B1 in `BLOCKER.md` (a follow-up package for six suites).
- Reviewer: run the delay check above.

## Plan check

Package issue still matches: yes
