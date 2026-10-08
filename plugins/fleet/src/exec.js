'use strict';

/*
 * Process execution for fleet. Every call takes an argv array and never a
 * shell string: repo names, branch names and issue bodies all come from the
 * tracker and must never be interpolated into a command line.
 */

const { spawnSync, spawn } = require('child_process');
const fs = require('fs');

const DEFAULT_TIMEOUT_MS = 120000;

// run(bin, args, opts) -> { status, stdout, stderr, error }
// Never throws. A binary that is missing or times out reports status null and
// an error string, so a caller can decide; most callers treat it as a fault.
function run(bin, args, opts = {}) {
  const r = spawnSync(bin, args, {
    cwd: opts.cwd,
    env: opts.env || process.env,
    input: opts.input,
    encoding: 'utf8',
    timeout: opts.timeoutMs || DEFAULT_TIMEOUT_MS,
    maxBuffer: 64 * 1024 * 1024,
    stdio: ['pipe', 'pipe', 'pipe'],
  });
  return {
    status: r.status,
    stdout: r.stdout || '',
    stderr: r.stderr || '',
    error: r.error ? (r.error.code === 'ETIMEDOUT' ? `timed out after ${opts.timeoutMs || DEFAULT_TIMEOUT_MS}ms` : r.error.message) : null,
  };
}

// runJson: like run, but parses stdout. A parse failure is reported as error.
function runJson(bin, args, opts = {}) {
  const r = run(bin, args, opts);
  if (r.status !== 0 || r.error) return { ...r, json: null };
  try { return { ...r, json: JSON.parse(r.stdout || 'null') }; }
  catch (e) { return { ...r, json: null, error: `stdout is not JSON: ${e.message}` }; }
}

// spawnDetached: start a long-running command that outlives this process.
// stdout+stderr go to logPath; the exit code is written to exitPath by a tiny
// sh wrapper (write to a sibling, then rename), because a parent that has
// already exited cannot wait on the child. Returns { pid }.
//
// The wrapper is the one place a shell is used. Nothing from the tracker is
// in that shell string: the command and its arguments are passed to sh as
// positional parameters and expanded with "$@".
function spawnDetached(bin, args, { cwd, env, logPath, exitPath }) {
  const out = fs.openSync(logPath, 'a', 0o600);
  const script = 'exec >>"$1" 2>&1; shift; ep="$1"; shift; "$@"; rc=$?; printf "%s\\n" "$rc" > "$ep.tmp" && mv "$ep.tmp" "$ep"; exit $rc';
  const child = spawn('sh', ['-c', script, 'fleet-worker', logPath, exitPath, bin, ...args], {
    cwd,
    env,
    detached: true,
    stdio: ['ignore', out, out],
  });
  child.unref();
  fs.closeSync(out);
  return { pid: child.pid };
}

// Process liveness. kill(pid, 0) says a pid exists; the start time says it is
// still the process we launched and not a reuse of the number.
function isAlive(pid) {
  if (!pid) return false;
  try { process.kill(pid, 0); return true; } catch (e) { return e.code === 'EPERM'; }
}

// Start time as ps reports it (lstart), or null when ps cannot say.
function processStart(pid) {
  if (!pid) return null;
  const r = run('ps', ['-o', 'lstart=', '-p', String(pid)], { timeoutMs: 5000 });
  const s = (r.stdout || '').trim();
  return r.status === 0 && s ? s : null;
}

function signal(pid, sig) {
  try { process.kill(-pid, sig); return true; } catch { /* not a group leader, or gone */ }
  try { process.kill(pid, sig); return true; } catch { return false; }
}

module.exports = { run, runJson, spawnDetached, isAlive, processStart, signal };
