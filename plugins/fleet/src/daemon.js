'use strict';

/*
 * fleet daemon: a scheduler around the existing cycle, for one or more configs.
 *
 * The cycle stays the unit. Each cycle is `fleet cycle --apply --json --config
 * <file>` run as a child process, so it is the same function the command runs,
 * with the same lock, latch, report and exit codes, and the daemon makes no
 * tracker writes of its own. A child per cycle is also what lets configs run
 * independently: runCycle is synchronous (every step is spawnSync, exec.js), so
 * run in this process one config's slow cycle would stall every other config.
 *
 * Triggers, per config:
 *   - the interval: at start, then every interval;
 *   - a worker's exit: a new *.exit file in <stateDir>/logs (store.exitPath,
 *     written by exec.spawnDetached when a detached worker ends). The first new
 *     file opens a coalescing window; every exit inside it is one cycle, run
 *     when the window closes.
 *
 * A trigger that arrives while that config's cycle runs is queued once, not
 * stacked. A config whose state is latched gets no cycles until `fleet resume`
 * clears it; the daemon logs the latch once and polls the state file for the
 * resume. On SIGTERM or SIGINT it starts nothing new, waits for cycles in
 * progress and exits 0. It never signals a cycle or a worker: cycles run in
 * their own process group and workers are detached by the launcher.
 *
 * Output: one line per cycle on stdout, `<time> <config> <OUTCOME> <cycleId>`;
 * a cycle that produces no report prints FAILED with its exit code instead.
 * Daemon events (latch, resume, stop) are lines on stdout too; the cycle's own
 * stderr passes through.
 *
 * Test-only overrides, in milliseconds: FLEET_DAEMON_INTERVAL_MS (every config),
 * FLEET_DAEMON_COALESCE_MS, FLEET_DAEMON_POLL_MS.
 */

const fs = require('fs');
const path = require('path');
const { spawn } = require('child_process');
const { loadConfig } = require('./config');

const MINUTE = 60000;
const DEFAULT_INTERVAL_MINUTES = 20;
const COALESCE_MS = 60000;
const POLL_MS = 2000;
const MAX_TIMER_MS = 2 ** 31 - 1;

function usageError(msg) {
  const e = new Error(`fleet daemon: ${msg}`);
  e.code = 'EUSAGE';
  return e;
}

function positive(value, what) {
  const n = Number(value);
  if (value === undefined || value === null || value === '' || value === true || !Number.isFinite(n) || n <= 0) {
    throw usageError(`${what} must be a positive number, got [${value}]`);
  }
  return n;
}

function envMs(name, dflt) {
  return process.env[name] === undefined ? dflt : positive(process.env[name], name);
}

function readLatch(stateDir) {
  const file = path.join(stateDir, 'state.json');
  if (!fs.existsSync(file)) return null;
  // store.save writes tmp + rename, so a read sees a whole file.
  return JSON.parse(fs.readFileSync(file, 'utf8')).latched || null;
}

// exitFiles(stateDir) -> Map(name -> mtimeMs). The mtime matters: a relaunch
// that keeps its attempt number (reap.js, a crash before the record said
// running) writes the same <issue>-<attempt>.exit name again.
function exitFiles(stateDir) {
  const dir = path.join(stateDir, 'logs');
  let names;
  try { names = fs.readdirSync(dir).filter(f => f.endsWith('.exit')); }
  catch (e) { if (e.code === 'ENOENT') return new Map(); throw e; }
  const out = new Map();
  for (const f of names) {
    try { out.set(f, fs.statSync(path.join(dir, f)).mtimeMs); }
    catch (e) { if (e.code !== 'ENOENT') throw e; }
  }
  return out;
}

class Program {
  constructor(file, cfg, { intervalMs, coalesceMs, fleetBin, out, err }) {
    this.file = file;                    // as given on the command line; the log names it
    this.abs = path.resolve(file);
    this.cfg = cfg;
    this.intervalMs = intervalMs;
    this.coalesceMs = coalesceMs;
    this.fleetBin = fleetBin;
    this.out = out; this.err = err;
    this.child = null;
    this.pending = false;
    this.latched = false;
    this.stopping = false;
    this.window = null;
    this.timer = null;
    this.seen = exitFiles(cfg.stateDir);   // exits from before the daemon started are not triggers
    this.onIdle = () => {};
  }

  line(msg) { this.out(`${new Date().toISOString()} ${this.file} ${msg}`); }

  start() {
    this.timer = setInterval(() => this.trigger('interval'), this.intervalMs);
    this.trigger('start');
  }

  stop() {
    this.stopping = true;
    clearInterval(this.timer);
    clearTimeout(this.window);
    this.pending = false;
  }

  running() { return Boolean(this.child); }

  // Called every poll: new exit files, and the resume of a latched config.
  poll() {
    if (this.stopping) return;
    let fresh = 0;
    for (const [f, mtime] of exitFiles(this.cfg.stateDir)) if (this.seen.get(f) !== mtime) { this.seen.set(f, mtime); fresh++; }
    if (this.latched) {
      let latch;
      try { latch = readLatch(this.cfg.stateDir); }
      catch (e) { this.err(`fleet daemon: ${this.file}: cannot read state.json to check the latch: ${e.message}`); return; }
      if (latch) return;
      this.latched = false;
      this.line('RESUMED latch cleared; cycling again');
      this.trigger('resume');
      return;
    }
    if (fresh && !this.window) {
      this.window = setTimeout(() => { this.window = null; this.trigger('exit'); }, this.coalesceMs);
    }
  }

  trigger(why) {
    if (this.stopping || this.latched) return;
    if (this.child) { this.pending = true; return; }
    // The cycle checks the latch itself (cycle.js); reading it here only spares
    // a latched config a process. If state.json cannot be read, the cycle runs
    // and reports the latch or the fault, and the trigger is not lost.
    let latch = null;
    try { latch = readLatch(this.cfg.stateDir); }
    catch (e) { this.err(`fleet daemon: ${this.file}: cannot read state.json to check the latch; the cycle will check it: ${e.message}`); }
    if (latch) { this.enterLatch(latch); return; }
    this.run(why);
  }

  enterLatch(latch) {
    if (this.latched) return;
    this.latched = true;
    this.pending = false;
    clearTimeout(this.window); this.window = null;
    this.line(`LATCHED ${latch.reason || 'stop condition fired'} at ${latch.at || '?'}; no cycles until \`fleet resume --reason <text> --config ${this.file}\``);
  }

  run(why) {
    const chunks = [];
    // detached: the cycle gets its own process group, so a terminal's SIGINT to
    // the daemon's group does not interrupt a cycle the daemon is waiting for.
    const child = spawn(process.execPath, [this.fleetBin, 'cycle', '--apply', '--json', '--config', this.abs], {
      stdio: ['ignore', 'pipe', 'inherit'],
      detached: true,
      env: process.env,
    });
    this.child = child;
    let ended = false;
    child.stdout.on('data', c => chunks.push(c));
    // A spawn failure emits 'error' and may or may not emit 'close'; either
    // way the cycle is over exactly once.
    child.on('error', e => {
      this.err(`fleet daemon: ${this.file}: cycle process error (${why}): ${e.message}`);
      if (child.pid === undefined) child.emit('close', null, null);
    });
    child.on('close', (code, signal) => {
      if (ended) return;
      ended = true;
      this.child = null;
      let r = null;
      try { r = JSON.parse(Buffer.concat(chunks).toString('utf8')); } catch { r = null; }
      if (r && r.outcome && r.cycleId) {
        this.line(`${String(r.outcome).toUpperCase()} ${r.cycleId}`);
      } else {
        this.line(`FAILED exit=${signal ? `signal ${signal}` : code} trigger=${why}; the cycle printed no report`);
      }
      const latch = r && (r.latched || ((r.alarms || []).some(a => a.code === 'latched') ? { reason: 'latched', at: r.at } : null));
      if (latch) this.enterLatch(latch);
      if (this.pending && !this.stopping && !this.latched) { this.pending = false; this.run('queued'); return; }
      this.pending = false;
      this.onIdle();
    });
  }
}

// start({ files, intervalMinutes, fleetBin, out, err }) -> { programs, stop }
// Throws EUSAGE or ECONFIG before anything runs; the caller maps both to 64.
function start({ files, intervalMinutes, fleetBin, out = s => process.stdout.write(s + '\n'), err = s => process.stderr.write(s + '\n') }) {
  if (!files.length) throw usageError('at least one --config is required');
  const cliMinutes = intervalMinutes === undefined ? DEFAULT_INTERVAL_MINUTES : positive(intervalMinutes, '--interval');
  const testInterval = process.env.FLEET_DAEMON_INTERVAL_MS === undefined ? null : envMs('FLEET_DAEMON_INTERVAL_MS');
  const coalesceMs = envMs('FLEET_DAEMON_COALESCE_MS', COALESCE_MS);
  const pollMs = envMs('FLEET_DAEMON_POLL_MS', POLL_MS);

  const programs = [];
  const seenFiles = new Map(), seenState = new Map();
  for (const file of files) {
    const cfg = loadConfig(file);
    const abs = path.resolve(file);
    if (seenFiles.has(abs)) throw usageError(`${file} is given twice`);
    if (seenState.has(cfg.stateDir)) throw usageError(`${file} and ${seenState.get(cfg.stateDir)} share stateDir ${cfg.stateDir}; each config needs its own lock, latch and exit files`);
    seenFiles.set(abs, file); seenState.set(cfg.stateDir, file);
    // Per-config override: daemonIntervalMinutes in the config file.
    const minutes = cfg.daemonIntervalMinutes === undefined ? cliMinutes : positive(cfg.daemonIntervalMinutes, `${file}: daemonIntervalMinutes`);
    const intervalMs = testInterval || minutes * MINUTE;
    // Above this, Node clamps a timer to 1ms and the config would cycle back to back.
    if (intervalMs > MAX_TIMER_MS) throw usageError(`${file}: interval ${intervalMs}ms exceeds the timer limit of ${MAX_TIMER_MS}ms (about ${Math.floor(MAX_TIMER_MS / MINUTE)} minutes)`);
    programs.push(new Program(file, cfg, { intervalMs, coalesceMs, fleetBin, out, err }));
  }

  const poller = setInterval(() => {
    for (const p of programs) {
      try { p.poll(); } catch (e) { err(`fleet daemon: ${p.file}: poll failed: ${e.message}`); }
    }
  }, pollMs);

  let stopping = false;
  const done = () => { if (stopping && !programs.some(p => p.running())) { clearInterval(poller); process.exit(0); } };
  const stop = sig => {
    if (stopping) return;
    stopping = true;
    const busy = programs.filter(p => p.running()).map(p => p.file);
    out(`${new Date().toISOString()} daemon stopping on ${sig}; ${busy.length ? `waiting for the cycle in progress: ${busy.join(', ')}` : 'no cycle in progress'}`);
    for (const p of programs) p.stop();
    done();
  };
  for (const p of programs) p.onIdle = done;
  process.on('SIGTERM', () => stop('SIGTERM'));
  process.on('SIGINT', () => stop('SIGINT'));

  out(`${new Date().toISOString()} daemon started: ${programs.map(p => `${p.file} every ${p.intervalMs / MINUTE}m`).join(', ')}; exits coalesce over ${coalesceMs / 1000}s`);
  for (const p of programs) p.start();
  return { programs, stop };
}

module.exports = { start, Program, DEFAULT_INTERVAL_MINUTES, COALESCE_MS };
