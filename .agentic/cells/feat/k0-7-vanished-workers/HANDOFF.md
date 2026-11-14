# HANDOFF: K0.7 — a worker that dies without an exit file is an alarm, not movement

## Done

- `plugins/fleet/src/reap.js` `classify()`: a session at `running` with a pid, not killed on timeout by reap, with no exit file is `vanished` (`next: relaunch`, `reason: worker-vanished`). The event records the pid, the lifetime bounded by the last log write and the reap, and this run's log bytes. A `launching` record stays `crash-before-run`. A session with an exit file is classified exactly as before. PR and BLOCKER still take precedence.
- `reap()`: keeps `state.vanished[<package id>]` as `[{ at, attempt, logPath, logSize }]`, pruned to `sessionTimeoutMinutes`. The second vanishing inside the window sets `next: null` and `reason: worker-vanished-repeat`, so nothing is relaunched.
- `plugins/fleet/src/cycle.js`:
  - Raises the alarm `worker-vanished` (package, pid, lifetime, log bytes) or `worker-vanished-repeat`.
  - A vanished relaunch is never a `dispatch` movement and does not count as live for the streak.
  - A vanished relaunch held over by wip-cap or a failed launch raises `worker-vanished` on the cycle that finally makes it.
  - Both codes are in `FAULT`, so a cycle with no other movement is `alarm`.
- `plugins/fleet/README.md`: reap behavior, plus the supervisor note (`KillMode=process` under systemd). `plugins/fleet/DAEMON.md` already carried the `KillMode=process` note (lines 51-71, from K0.5), so no out-of-lane edit was needed.
- `plugins/fleet/tests/vanished.test.sh`:
  - Unit rows for classify and the repeat window.
  - An end-to-end cycle that SIGKILLs the stub worker's process group, the same thing a control-group kill does.
  - Against the pre-change tree it failed 19 of 34 checks. It reproduced the incident: relaunch, `dispatch` movement, streak stuck at 0. After the change, `bash scripts/test.sh` ends `ALL PASS`.

## Review (implement+review)

An independent review found that a timeout kill was being classified as vanished. `src/exec.js:81` signals the process group, so the wrapper writes no exit file. This is fixed with `!session.killedAt` and covered by a test. The review's other findings are also fixed: the unreported deferred relaunch, the lifetime measured only to reap, and the log size counting the appended previous run.

## Next / open

- `plugins/fleet/skills/fleet/SKILL.md` has no entry for `worker-vanished` or `worker-vanished-repeat` in its alarm list. It is outside this lane and should be added in a follow-up.
- A `worker-vanished-repeat` hold, like `escalation-cap`, stays until the coordinator acts. No command releases it.

## Plan check

Package issue still matches: yes
