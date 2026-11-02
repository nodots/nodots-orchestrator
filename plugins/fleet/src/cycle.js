'use strict';

/*
 * One pass: lock → sync → promote → assign → launch → reap → report → unlock.
 *
 * Every step reads the tracker fresh; the only local memory is the session
 * table, the dispatch history and the no-movement streak. A failure in sync
 * or assign aborts before anything is launched: labels derived from partial
 * state are wrong, and a launch on top of them compounds it.
 *
 * Dry run (the default) runs the same code with every write disabled: the
 * scripts in dry-run mode, promotion and assignment computed but not applied,
 * launches described but not made, sessions classified but not persisted.
 */

const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const { Store } = require('./store');
const { Tracker } = require('./tracker');
const scripts = require('./scripts');
const { promote } = require('./promote');
const scope = require('./scope');
const launchMod = require('./launch');
const reapMod = require('./reap');
const report = require('./report');

const EXIT = { ok: 0, labelWriteFailed: 1, usage: 64, missingBinary: 69, internal: 70, truncated: 75, latched: 78, locked: 79 };

function cycleId() { return `${new Date().toISOString().replace(/[-:]/g, '').replace(/\.\d+Z$/, 'Z')}-${crypto.randomBytes(2).toString('hex')}`; }

function counts(issues, syncState, live, cfg) {
  const labelOf = i => (i.labels || []).find(l => l.startsWith('cell:')) || null;
  const open = issues.filter(i => String(i.state).toUpperCase() === 'OPEN');
  const n = l => open.filter(i => labelOf(i) === l).length;
  const merged = issues.filter(i => labelOf(i) === 'cell:merged').length;
  const inFlight = n('cell:active') + open.filter(i => labelOf(i) === 'cell:queued' && (i.labels || []).some(l => l.startsWith('worker:'))).length;
  return { open: open.length, queued: n('cell:queued'), active: n('cell:active'), awaitingReview: n('cell:awaiting-review'), blocked: n('cell:blocked'), merged, live: live.length, wipCap: cfg.wipCap, wipFree: Math.max(0, cfg.wipCap - inFlight) };
}

function runCycle(cfg, { apply = false, log = () => {} } = {}) {
  const store = new Store(cfg.stateDir);
  const tracker = new Tracker(cfg.bins);
  const id = cycleId();
  const at = new Date().toISOString();
  const r = { cycleId: id, at, dryRun: !apply, outcome: null, movement: [], counts: {}, alarms: [], launched: [], reaped: [], escalations: [], parked: [], promoted: [], assigned: [], held: [], sync: null, streak: 0, latched: null };
  const alarm = (code, detail, issue) => r.alarms.push({ code, detail, issue });

  const lock = store.lock(cfg.maxCycleMinutes * 60000);
  if (!lock.ok) { alarm('locked', lock.reason); r.outcome = 'alarm'; return { report: r, exit: EXIT.locked }; }
  if (store.staleTakeover) log(`took over a stale lock (${store.staleTakeover.reason}) from ${JSON.stringify(store.staleTakeover.holder)}`);

  let state = store.load();
  let exit = EXIT.ok;
  try {
    if (state.latched && apply) {
      alarm('latched', `stop condition fired at ${state.latched.at} after ${state.latched.streak} cycles without movement; run \`fleet resume --reason <text>\``);
      r.outcome = 'alarm'; r.streak = state.streak; r.latched = state.latched;
      return { report: r, exit: EXIT.latched };
    }

    // 1. sync: derive cell:* labels; read the state it derived from.
    const emitPath = path.join(cfg.stateDir, 'sync-state.json');
    const sync = scripts.runSync(cfg, { apply, emitPath });
    r.sync = { status: sync.status, changes: sync.rows.filter(x => x.changed), failedWrites: sync.failedWrites };
    if (sync.status !== 0 || !sync.state) {
      alarm('sync-failed', `sync-cells.sh exited ${sync.status === null ? sync.error : sync.status}: ${sync.stderr.trim().split('\n')[0] || 'no stderr'}`);
      r.outcome = 'alarm';
      return { report: r, exit: sync.status === 75 ? EXIT.truncated : sync.status === 69 ? EXIT.missingBinary : EXIT.internal };
    }
    if (sync.failedWrites) { alarm('sync-label-write-failed', `${sync.failedWrites} label write(s) failed`); exit = EXIT.labelWriteFailed; }
    for (const row of r.sync.changes) {
      if (row.to === 'cell:merged') r.movement.push({ package: scope.packageId((sync.state.issues.find(i => i.number === row.number) || {}).title) || `#${row.number}`, issue: row.number, artifact: { type: 'merged', ref: row.why } });
    }

    // Fresh issue list with bodies: promotion and launch read SCOPE.json from it.
    const list = tracker.listIssues(cfg.repo);
    if (!list.ok) { alarm('issues-failed', list.error); r.outcome = 'alarm'; return { report: r, exit: list.truncated ? EXIT.truncated : EXIT.internal }; }
    let issues = list.issues;

    // 2. promote
    const pr = promote(issues, sync.state);
    r.held = pr.held;
    for (const e of pr.edits) {
      if (apply) {
        const w = tracker.addLabel(cfg.repo, e.number, e.add);
        if (!w.ok) { alarm('promote-write-failed', w.error, e.number); exit = EXIT.labelWriteFailed; continue; }
      }
      r.promoted.push(e);
      const iss = issues.find(i => i.number === e.number);
      if (iss && !iss.labels.includes(e.add)) iss.labels.push(e.add);   // so assign sees it this cycle
    }

    // 3. assign worker:<id> labels (fleet-wide WIP, every worker id)
    const asg = scripts.runAssign(cfg, { apply });
    if (asg.status !== 0 && asg.status !== 1) {
      alarm('assign-failed', `assign-cells.sh exited ${asg.status === null ? asg.error : asg.status}: ${asg.stderr.trim().split('\n')[0] || 'no stderr'}`);
      r.outcome = 'alarm';
      return { report: r, exit: asg.status === 75 ? EXIT.truncated : asg.status === 69 ? EXIT.missingBinary : EXIT.internal };
    }
    if (asg.status === 1) { alarm('assign-label-write-failed', 'one or more worker labels failed to write'); exit = EXIT.labelWriteFailed; }
    r.assigned = asg.rows.filter(x => x.action === 'assign');
    r.assignHeld = asg.rows.filter(x => x.action !== 'assign');
    for (const a of r.assigned) {
      const iss = issues.find(i => i.number === a.number);
      if (iss && !iss.labels.includes(`worker:${a.worker}`)) iss.labels.push(`worker:${a.worker}`);
    }

    const synced = new Map(sync.state.issues.map(i => [i.number, i]));

    // 4. reap first, so a slot freed this cycle can be refilled below.
    const pulls = [];
    for (const t of cfg.targets) { const p = tracker.listPulls(t.repo); if (p.ok) pulls.push(...p.pulls.map(x => ({ ...x, repo: t.repo }))); else alarm('pulls-failed', p.error); }
    const reaped = reapMod.reap(cfg, state, pulls, Date.now(), s => { const x = synced.get(s.issue); return Boolean(x && x.blockerOnBranch); });
    r.reaped = reaped.reaped;
    for (const x of reaped.reaped) {
      if (x.outcome === 'pr') r.movement.push({ package: x.id, issue: x.issue, artifact: { type: 'pr', ref: x.artifact.ref, detail: x.detail } });
      if (x.outcome === 'parked') { r.parked.push(x); if (x.alarm) alarm('blocker-overdue', x.alarm, x.issue); }
    }

    // 5. launch: owned, queued, labeled packages without a session; plus relaunch/escalation requests.
    const persist = rec => { state.sessions[rec.issue] = rec; if (apply) store.save(state); };
    // FLEET_ONLY_ISSUE narrows `fleet launch <issue>` to one package without a
    // second launch path.
    const only = process.env.FLEET_ONLY_ISSUE ? Number(process.env.FLEET_ONLY_ISSUE) : null;
    // A package with a branch or a PR already has a worker on it, here or on
    // another account; only a reap request may relaunch it.
    const untouched = n => { const s = synced.get(n); return !s || (!s.branchExists && !s.pr); };
    // ...unless the branch is one this machine pushed and then lost track of: a
    // local worktree on the package branch with no session record is a launch
    // that crashed between its push and its record, and it is adopted.
    const orphaned = i => {
      const s = synced.get(i.number);
      if (!s || s.pr) return false;
      const d = scope.describe(i); if (d.problems.length) return false;
      const target = launchMod.targetFor(cfg, i); if (!target) return false;
      return Boolean(launchMod.localWorktreeOnBranch(cfg, target, d.id, d.scope.branch));
    };
    // Sync has already relabeled an orphan cell:active (its branch exists), so
    // adoption accepts that label; a fresh launch still needs cell:queued.
    const launchable = issues.filter(i => String(i.state).toUpperCase() === 'OPEN'
      && (only === null || i.number === only)
      && i.labels.some(l => l.startsWith('worker:') && cfg.ownedIds.includes(l.slice(7)))
      && !state.sessions[i.number]
      && ((i.labels.includes('cell:queued') && untouched(i.number))
        || ((i.labels.includes('cell:queued') || i.labels.includes('cell:active')) && orphaned(i))));
    let dispatchable = launchable.length;

    const requests = [];
    for (const i of launchable) {
      const d = scope.describe(i);
      if (d.problems.length) { alarm('unlaunchable', d.problems.join('; '), i.number); continue; }
      const worker = i.labels.find(l => l.startsWith('worker:')).slice(7);
      const prior = state.dispatches[d.id] || [];
      requests.push({ issue: i, id: d.id, sc: d.scope, workerId: worker, attempt: prior.length + 1, tier: (d.scope.execution && d.scope.execution.model) || 'default', reason: null });
    }
    for (const q of reaped.requests) {
      const s = q.session;
      const iss = issues.find(i => i.number === s.issue);
      if (!iss) continue;
      const d = scope.describe(iss);
      if (d.problems.length) { alarm('unlaunchable', d.problems.join('; '), s.issue); s.status = 'retry'; s.retry = { next: q.next, reason: q.reason, why: d.problems.join('; ') }; continue; }
      const prior = state.dispatches[s.id] || [];
      if (q.next === 'unpark') {
        requests.push({ issue: iss, id: s.id, sc: d.scope, workerId: s.worker, attempt: s.attempt + 1, tier: s.tier, reason: 'unparked', from: s, next: 'unpark' });
        dispatchable += 1;
        continue;
      }
      if (q.next === 'escalate') {
        const escalations = Math.max(0, prior.length - 1);
        if (escalations >= cfg.maxEscalations) { alarm('escalation-cap', `${s.id} has been escalated ${escalations} time(s); last: ${q.reason}. Holding.`, s.issue); continue; }
        const to = launchMod.tierUp(s.tier);
        r.escalations.push({ package: s.id, issue: s.issue, n: escalations + 1, from: s.tier, to, reason: q.reason });
        requests.push({ issue: iss, id: s.id, sc: d.scope, workerId: s.worker, attempt: s.attempt + 1, tier: to, reason: q.reason, from: s, next: 'escalate' });
      } else {
        requests.push({ issue: iss, id: s.id, sc: d.scope, workerId: s.worker, attempt: s.attempt, tier: s.tier, reason: q.reason, relaunch: true, from: s, next: 'relaunch' });
      }
      dispatchable += 1;
    }

    const liveNow = reaped.live.length;
    let slots = Math.max(0, cfg.wipCap - liveNow);
    for (const q of requests) {
      if (slots <= 0) {
        alarm('wip-cap', `${q.id} waits: ${liveNow} live session(s) already fill the cap`, q.issue.number);
        if (q.from) { q.from.status = 'retry'; q.from.retry = { next: q.next, reason: q.reason, why: 'wip-cap' }; }
        continue;
      }
      const out = launchMod.launch(cfg, tracker, store, { ...q, dryRun: !apply }, persist);
      if (!out.ok) {
        alarm(`launch-${out.stage}`, out.error, q.issue.number);
        if (q.from) { q.from.status = 'retry'; q.from.retry = { next: q.next, reason: q.reason, why: `launch-${out.stage}: ${out.error}` }; }
        continue;
      }
      if (q.from && q.from.status === 'retry') { q.from.status = 'closed'; delete q.from.retry; }
      slots -= 1;
      r.launched.push({ issue: q.issue.number, id: q.id, worker: q.workerId, mode: out.session.mode, tier: q.tier, attempt: q.attempt, branch: q.sc.branch, worktree: out.session.worktree, pid: out.session.pid || null, adopted: Boolean(out.adopted), recut: Boolean(out.recut), ci: out.session.ci || null });
      // A relaunch repeats a dispatch rather than adding one, except when the
      // original's record was lost to a crash before it was written.
      if (!state.dispatches[q.id]) state.dispatches[q.id] = [];
      if (!q.relaunch || state.dispatches[q.id].length < q.attempt) {
        state.dispatches[q.id].push({ n: q.attempt, tier: q.tier, reason: q.reason, runId: out.session.sessionId || null, ts: at, recovered: Boolean(q.relaunch) || undefined });
      }
      if (!out.dryRun) r.movement.push({ package: q.id, issue: q.issue.number, artifact: { type: 'dispatch', ref: q.sc.branch, detail: `attempt ${q.attempt}` } });
    }

    // 6. outcome, streak, latch
    const liveAfter = reaped.live.length + r.launched.filter(l => l.pid).length;
    r.counts = counts(issues, sync.state, { length: liveAfter }, cfg);
    // Faults that make the cycle an alarm when nothing moved. A WIP-cap hold
    // is not one: a full fleet with nothing else to do is exhaustion.
    const FAULT = /(-failed$|^locked$|^latched$|^escalation-cap$|^launch-|^unlaunchable$)/;
    if (r.alarms.some(a => FAULT.test(a.code)) && r.movement.length === 0) r.outcome = 'alarm';
    else if (r.movement.length) r.outcome = 'movement';
    else if (dispatchable > 0 && r.launched.length === 0) r.outcome = 'alarm';
    else r.outcome = 'exhaustion';
    if (r.outcome === 'alarm' && !r.alarms.length) alarm('no-movement', `${dispatchable} package(s) were dispatchable and none launched`);

    if (apply) {
      if (r.outcome === 'movement') state.streak = 0;
      else if (liveAfter === 0) state.streak += 1;
      if (state.streak >= cfg.noMovementLimit && !state.latched) {
        const parked = Object.values(state.sessions).filter(s => s.status === 'parked').map(s => `${s.id} (#${s.issue})`);
        state.latched = { at, streak: state.streak, reason: `${state.streak} consecutive cycles without movement${parked.length ? `; parked and waiting on a decision: ${parked.join(', ')}` : ''}` };
      }
      state.lastCycleId = id;
      state.unposted = [...(state.unposted || []), id];
      store.save(state);
    }
    r.streak = state.streak; r.latched = state.latched;

    // 7. report
    if (apply) {
      store.writeCycle(r);
      const posted = report.post(tracker, cfg, r);
      if (posted.ok) { state.unposted = state.unposted.filter(x => x !== id); store.save(state); }
      else alarm('report-post-failed', posted.error);
    }
    if (r.latched && r.outcome !== 'alarm') exit = Math.max(exit, EXIT.latched);
    return { report: r, exit };
  } finally {
    store.unlock();
  }
}

module.exports = { runCycle, counts, EXIT };
