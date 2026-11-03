# fleet daemon

`fleet daemon` runs `fleet cycle --apply` for one or more programs, on an interval and whenever a worker exits. It replaces the per-program systemd timer: one daemon serves every program on the host, and a finished worker's slot is refilled about a minute after the worker exits instead of at the next timer tick.

```
fleet daemon --config <a.json> [--config <b.json> ...] [--interval <minutes>]
```

With no `--config`, it uses `FLEET_CONFIG`, else `./fleet.config.json`, as the other commands do.

## What it does

- **The cycle is unchanged.** Each cycle is `fleet cycle --apply --json --config <file>` run as a child process. The lock, the latch, the alarms, the cycle report and the epic comment behave exactly as they do when you run the command by hand. The daemon writes nothing to the tracker.
- **Interval.** Each config cycles once at start, then every 20 minutes. `--interval <minutes>` changes the default for every config; `"daemonIntervalMinutes": <n>` in a config file overrides it for that config.
- **Worker exit.** A detached worker writes `<stateDir>/logs/<issue>-<attempt>.exit` when it ends. The daemon polls that directory every 2 seconds. The first new exit file, or one rewritten since the last poll, opens a 60-second window, and every exit inside the window becomes one cycle, run when the window closes. Exit files present when the daemon starts are not triggers.
- **No overlap.** A trigger that arrives while that config's cycle runs is queued once: the running cycle is followed by exactly one more, however many triggers arrived. Configs are independent; each cycle is its own process, so one config's slow or failing cycle does not delay another's.
- **Latch.** A config whose state is latched gets no cycles. The daemon logs the latch once and checks the state file on every poll; after `fleet resume --reason <text> --config <file>` it logs `RESUMED` and cycles that config at once. The other configs keep cycling throughout.
- **Stop.** On SIGTERM or SIGINT the daemon starts nothing new, waits for any cycle in progress to finish and exits 0. It never signals a cycle or a worker. Cycles run in their own process group, and workers are detached by the launcher, so both outlive the daemon as workers outlive a cycle today.

Two configs may not share a `stateDir`; the daemon refuses to start (exit 64), because each config needs its own lock, latch and exit files.

## Output

One line per cycle on stdout, so `journalctl` shows what happened:

```
2026-11-02T14:20:03.512Z /etc/fleet/program-k.json MOVEMENT 20261102T142001Z-9f3a
2026-11-02T14:20:04.100Z /etc/fleet/program-v.json EXHAUSTION 20261102T142001Z-c41e
```

The fields are the time the cycle ended, the config as given on the command line, the outcome (`MOVEMENT`, `EXHAUSTION` or `ALARM`) and the cycle id. The full report is in `<stateDir>/cycles/<cycle id>.json`. A cycle that prints no report, for example one that exits 64 on a config error, logs `FAILED exit=<code>` instead. The daemon also logs `LATCHED`, `RESUMED`, its start and its stop on stdout. Each cycle's own stderr passes through to the daemon's stderr.

## Running it under systemd

A user unit keeps the daemon up across crashes and logins. Enable lingering once so it runs without an open session: `loginctl enable-linger $USER`.

`~/.config/systemd/user/fleet-daemon.service`:

```ini
[Unit]
Description=fleet daemon: cycles for every program on this host
After=network-online.target

[Service]
Type=simple
WorkingDirectory=%h
Environment=PATH=%h/.local/bin:/usr/local/bin:/usr/bin:/bin
ExecStart=/usr/bin/env node %h/path/to/plugins/fleet/bin/fleet.js daemon \
  --config %h/fleet/program-k.json \
  --config %h/fleet/program-v.json
# Workers must outlive the daemon. The default KillMode=control-group kills
# every process the unit started when it stops or restarts, workers included.
KillMode=process
# Let a cycle in progress finish before systemd gives up on the stop.
TimeoutStopSec=35min
Restart=on-failure
RestartSec=30

[Install]
WantedBy=default.target
```

Set `TimeoutStopSec` above the longest `maxCycleMinutes` among the configs. Then:

```
systemctl --user daemon-reload
systemctl --user enable --now fleet-daemon.service
journalctl --user -u fleet-daemon -f
```

`KillMode=process` matters. Under the default, a `Type=oneshot` cycle unit killed every worker it launched when the cycle exited, and the same happens to a daemon unit on every stop or restart. With `KillMode=process`, systemd sends SIGTERM to the daemon alone and leaves its cycles and workers running.

## Replacing the per-program timers

Stop and disable each program's timer before enabling the daemon. A timer cycle and a daemon cycle for the same config never run at once, because the second one finds the lock held and reports an `ALARM` (exit 79), but that alarm is noise.

```
systemctl --user list-timers            # find the program's timer
systemctl --user disable --now <the program's timer>.timer
```

Add the program's config to the daemon's `ExecStart` as another `--config`.

## Test-only overrides

`daemon.test.sh` scales the timings down through environment variables, in milliseconds: `FLEET_DAEMON_INTERVAL_MS` (overrides the interval of every config), `FLEET_DAEMON_COALESCE_MS` and `FLEET_DAEMON_POLL_MS`. Do not set them in production.
