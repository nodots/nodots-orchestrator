'use strict';

/*
 * Runs the plugin's own scripts and reads their results. The label derivation
 * lives in sync-cells.sh and the assignment logic in assign-cells.sh; fleet
 * does not re-implement either. It reads sync's decisions from the state file
 * that --emit-state writes, and both scripts' human rows for the report.
 */

const fs = require('fs');
const os = require('os');
const path = require('path');
const { run } = require('./exec');
const { Tracker } = require('./tracker');
const { partOf } = require('./scope');

// "#101  cell:active -> cell:merged   (PR #201 merged)"
// "#106  cell:queued   (unchanged: no rule matched)"
const SYNC_CHANGE = /^#(\d+)\s+(\S+) -> (\S+)\s+\((.*)\)$/;
const SYNC_KEEP = /^#(\d+)\s+(\S+)\s+\(unchanged: (.*)\)$/;
// "#12  assign -> worker:a   (least loaded: a=0 b=1)"
// "#13  hold   (WIP cap reached (4/4 in flight))"
// "#14  !      carries worker:a and worker:b; one owner only."
const ASSIGN_ROW = /^#(\d+)\s+(assign -> worker:(\S+)|hold|!)\s+(?:\((.*)\)|(.*))$/;
const LOAD_LINE = /^load: (.*); (.*)$/;

function parseSyncRows(stdout) {
  const rows = [];
  for (const line of stdout.split('\n')) {
    let m;
    if ((m = SYNC_CHANGE.exec(line))) rows.push({ number: Number(m[1]), from: m[2] === 'none' ? null : m[2], to: m[3], changed: true, why: m[4] });
    else if ((m = SYNC_KEEP.exec(line))) rows.push({ number: Number(m[1]), from: m[2] === 'none' ? null : m[2], to: m[2] === 'none' ? null : m[2], changed: false, why: m[3] });
  }
  return rows;
}

function parseAssignRows(stdout) {
  const rows = [];
  let load = null;
  for (const line of stdout.split('\n')) {
    let m;
    if ((m = ASSIGN_ROW.exec(line))) {
      const action = m[2].startsWith('assign') ? 'assign' : m[2] === 'hold' ? 'hold' : 'warn';
      rows.push({ number: Number(m[1]), action, worker: m[3] || null, why: (m[4] !== undefined ? m[4] : m[5] || '').trim() });
    } else if ((m = LOAD_LINE.exec(line))) {
      load = { perWorker: m[1], inFlight: m[2] };
    }
  }
  return { rows, load };
}

function runSync(cfg, { apply, emitPath }) {
  const script = path.join(cfg.scriptsDir, 'sync-cells.sh');
  const args = [script, '--repo', cfg.repo];
  for (const t of cfg.targets) args.push('--target', t.repo);
  // Only the epic's packages: a host repo's other programs cost no per-package
  // calls, and their uncollected repos cannot fail the sync.
  args.push('--epic', String(cfg.epic));
  if (emitPath) args.push('--emit-state', emitPath);
  if (apply) args.push('--apply');
  const env = { ...process.env, GH_BIN: cfg.bins.gh };
  const r = run('bash', args, { env, timeoutMs: 10 * 60 * 1000 });
  let state = null;
  if (emitPath && fs.existsSync(emitPath)) { try { state = JSON.parse(fs.readFileSync(emitPath, 'utf8')); } catch { state = null; } }
  const failedWrites = (r.stderr.match(/! failed to (?:re)?label #\d+/g) || []).length;
  return { status: r.status, error: r.error, stdout: r.stdout, stderr: r.stderr, rows: parseSyncRows(r.stdout), state, failedWrites };
}

// The open packages of the config's epic, in the shape assign-cells.sh --state
// reads. Left to collect for itself, assign-cells.sh reads every open issue in
// the host repo and would assign, and count toward the WIP cap, another
// program's packages.
function assignState(cfg, issues) {
  return {
    repo: cfg.repo,
    issues: issues
      .filter(i => String(i.state).toUpperCase() === 'OPEN' && partOf(i.body) === cfg.epic)
      .map(i => ({ number: i.number, title: i.title, state: i.state, labels: i.labels })),
  };
}

function runAssign(cfg, { apply }) {
  const list = new Tracker(cfg.bins).listIssues(cfg.repo);
  if (!list.ok) {
    return { status: list.truncated ? 75 : 70, error: null, stdout: '', stderr: `fleet: issue list for assign: ${list.error}\n`, rows: [], load: null };
  }
  let dir;
  try { dir = fs.mkdtempSync(path.join(os.tmpdir(), 'fleet-assign-')); }
  catch (e) { return { status: 70, error: null, stdout: '', stderr: `fleet: no temp dir for the assign state: ${e.message}\n`, rows: [], load: null }; }
  try {
    const statePath = path.join(dir, 'state.json');
    fs.writeFileSync(statePath, JSON.stringify(assignState(cfg, list.issues)));
    const script = path.join(cfg.scriptsDir, 'assign-cells.sh');
    // --state supplies the packages; --repo is where --apply writes the labels.
    const args = [script, '--state', statePath, '--repo', cfg.repo, '--workers', cfg.workerIds.join(','), '--wip-cap', String(cfg.wipCap)];
    if (apply) args.push('--apply');
    const env = { ...process.env, GH_BIN: cfg.bins.gh };
    const r = run('bash', args, { env, timeoutMs: 10 * 60 * 1000 });
    const parsed = parseAssignRows(r.stdout);
    return { status: r.status, error: r.error, stdout: r.stdout, stderr: r.stderr, rows: parsed.rows, load: parsed.load };
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
}

module.exports = { runSync, runAssign, assignState, parseSyncRows, parseAssignRows };
