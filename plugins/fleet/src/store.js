'use strict';

/*
 * Durable local state and the cycle lock.
 *
 * What lives here is only what the tracker cannot know: which local process
 * runs which package, when it started, how many times a package has been
 * dispatched, and the no-movement streak. Labels, PRs and the queue are
 * re-derived from the tracker every cycle and never cached here.
 *
 * Writes are tmp + fsync + rename, so a crash leaves either the old file or
 * the new one, never half of one.
 */

const fs = require('fs');
const path = require('path');
const os = require('os');
const { run, isAlive } = require('./exec');

const EMPTY = () => ({
  version: 1,
  sessions: {},     // issue number -> session record
  dispatches: {},   // package id -> [{ n, tier, reason, runId, ts }]
  streak: 0,
  latched: null,    // { at, streak, reason } when the stop condition fired
  lastCycleId: null,
  unposted: [],     // cycle ids whose report has not reached the epic yet
});

function bootId() {
  // Linux has a stable per-boot id. macOS has the boot time. Either one
  // changes across a reboot, which is what the lock needs to notice.
  try { return fs.readFileSync('/proc/sys/kernel/random/boot_id', 'utf8').trim(); } catch { /* not linux */ }
  const r = run('sysctl', ['-n', 'kern.boottime'], { timeoutMs: 5000 });
  if (r.status === 0 && r.stdout.trim()) return r.stdout.trim().replace(/\s+/g, ' ');
  return `uptime:${Math.round((Date.now() - os.uptime() * 1000) / 60000)}`;
}

function atomicWrite(file, text, mode = 0o600) {
  const tmp = `${file}.tmp`;
  const fd = fs.openSync(tmp, 'w', mode);
  try { fs.writeSync(fd, text); fs.fsyncSync(fd); } finally { fs.closeSync(fd); }
  fs.renameSync(tmp, file);
}

class Store {
  constructor(stateDir) {
    this.dir = stateDir;
    this.file = path.join(stateDir, 'state.json');
    this.lockFile = path.join(stateDir, 'cycle.lock');
    fs.mkdirSync(path.join(stateDir, 'logs'), { recursive: true, mode: 0o700 });
    fs.mkdirSync(path.join(stateDir, 'cycles'), { recursive: true, mode: 0o700 });
    try { fs.chmodSync(stateDir, 0o700); } catch { /* not ours to chmod */ }
  }

  load() {
    if (!fs.existsSync(this.file)) return EMPTY();
    const s = JSON.parse(fs.readFileSync(this.file, 'utf8'));
    return { ...EMPTY(), ...s };
  }

  save(state) {
    atomicWrite(this.file, JSON.stringify(state, null, 2) + '\n');
  }

  // lock() -> { ok: true } | { ok: false, holder, reason }
  // A stale lock (dead pid on this host, a different boot, or older than
  // maxAgeMs) is taken over; the old file is kept beside it for the record.
  lock(maxAgeMs) {
    const mine = { pid: process.pid, host: os.hostname(), bootId: bootId(), startedAt: new Date().toISOString() };
    for (let attempt = 0; attempt < 2; attempt++) {
      try {
        const fd = fs.openSync(this.lockFile, 'wx', 0o600);
        fs.writeSync(fd, JSON.stringify(mine));
        fs.closeSync(fd);
        return { ok: true };
      } catch (e) {
        if (e.code !== 'EEXIST') throw e;
      }
      let holder = null;
      try { holder = JSON.parse(fs.readFileSync(this.lockFile, 'utf8')); } catch { holder = { unreadable: true }; }
      const age = holder.startedAt ? Date.now() - Date.parse(holder.startedAt) : Infinity;
      const sameHost = holder.host === mine.host;
      const stale = holder.unreadable
        || (sameHost && holder.bootId !== mine.bootId)
        || (sameHost && !isAlive(holder.pid))
        || age > maxAgeMs;
      if (!stale) return { ok: false, holder, reason: `cycle ${holder.pid}@${holder.host} started ${holder.startedAt} still holds the lock` };
      const stamp = new Date().toISOString().replace(/[:.]/g, '-');
      try { fs.renameSync(this.lockFile, `${this.lockFile}.stale-${stamp}`); } catch { /* raced; loop once more */ }
      this.staleTakeover = { holder, reason: holder.unreadable ? 'unreadable' : (sameHost && holder.bootId !== mine.bootId) ? 'different boot' : (sameHost && !isAlive(holder.pid)) ? 'pid dead' : 'too old' };
    }
    return { ok: false, holder: null, reason: 'could not acquire the lock after a stale takeover' };
  }

  unlock() {
    try {
      const holder = JSON.parse(fs.readFileSync(this.lockFile, 'utf8'));
      if (holder.pid === process.pid) fs.unlinkSync(this.lockFile);
    } catch { /* not ours, or already gone */ }
  }

  logPath(issue, attempt) { return path.join(this.dir, 'logs', `${issue}-${attempt}.log`); }
  exitPath(issue, attempt) { return path.join(this.dir, 'logs', `${issue}-${attempt}.exit`); }
  cyclePath(id) { return path.join(this.dir, 'cycles', `${id}.json`); }

  writeCycle(report) { atomicWrite(this.cyclePath(report.cycleId), JSON.stringify(report, null, 2) + '\n'); }
}

module.exports = { Store, atomicWrite, bootId, EMPTY };
