# HANDOFF: K0.5 — fleet daemon

## Done

- `plugins/fleet/src/daemon.js`: scheduler around the existing cycle. Each cycle is `fleet cycle --apply --json --config <file>` as a child process (detached process group). Per config: a cycle at start, then on the interval; a new or rewritten `*.exit` in `<stateDir>/logs` opens a coalescing window (60s) that ends in one cycle. A trigger during a running cycle sets one pending follow-up. A latched config is skipped, logged once, and resumed when `state.json` shows the latch cleared. SIGTERM/SIGINT: no new cycles, wait for running ones, exit 0; nothing is signalled.
- `plugins/fleet/bin/fleet.js`: `daemon` command; the parser collects every `--config` (`flags.config` still holds the last, as before) and takes `--interval <minutes>`.
- Per-config interval override: `"daemonIntervalMinutes"` in the config file. `config.js` is forbidden to this lane; `validate` spreads unknown keys through (`config.js:96`), so the daemon validates the key itself.
- Test-only env: `FLEET_DAEMON_INTERVAL_MS`, `FLEET_DAEMON_COALESCE_MS`, `FLEET_DAEMON_POLL_MS`.
- `plugins/fleet/tests/daemon.test.sh` (44 checks) on `cycle.test.sh`'s harness, two programs (epics #1 and #2), with test-local wrappers that hold a stub worker until released and slow the gh stub to hold a cycle open.
- `plugins/fleet/DAEMON.md`: running it, a systemd user unit with `KillMode=process` (per the issue comment), replacing the timers.

## Why a child process, not an in-process call

`runCycle` is synchronous: every step goes through `spawnSync` (`exec.js:17-33`). Called in the daemon's process, one config's slow cycle would block every other config's timers, which the "configs run independently" requirement rules out. The child runs the same `runCycle` through the same command, so lock, latch, report and exit codes are those of `fleet cycle --apply`.

## Review

An independent review pass found 4 defects, all fixed with regression checks: `--config` with no value crashed (now exit 64); an interval past Node's 2^31-1 ms timer limit became a 1 ms timer (now exit 64); a relaunch that rewrites the same `<issue>-<attempt>.exit` name went unseen (now tracked by mtime); an unreadable `state.json` dropped the trigger (now the cycle runs and checks the latch itself).

## Next

- K0.1 / K0.3 own README and the skill; they may link DAEMON.md.
- The coordinator host's per-program timers are still in place; replacing them is an operator step (DAEMON.md, "Replacing the per-program timers").

## Plan check

Package issue still matches: yes
