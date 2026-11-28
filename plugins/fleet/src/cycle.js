'use strict';

/*
 * One pass: lock → sync → promote → assign → reap → verify → review → rework → merge → launch → report → unlock.
 * verify runs only for targets with `verify` (src/verify.js); review only
 * with `reviewers` configured, or a review still in flight (src/review.js);
 * merge only for targets with `autoMerge` (src/merge.js). With `coordinators`
 * set, a package whose coordinator labels came from another account is held
 * out of every step after sync (src/provenance.js).
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
const verifyMod = require('./verify');
const reviewMod = require('./review');
const reworkMod = require('./rework');
const mergeMod = require('./merge');
const provenance = require('./provenance');
const { requireReviewers, requireFleetCoordinator } = require('./config');

const EXIT = { ok: 0, labelWriteFailed: 1, usage: 64, missingBinary: 69, internal: 70, truncated: 75, latched: 78, locked: 79 };

function cycleId() { return `${new Date().toISOString().replace(/[-:]/g, '').replace(/\.\d+Z$/, 'Z')}-${crypto.randomBytes(2).toString('hex')}`; }

// awaitingLab and verifying exist only for a config with a verify target, and
// awaitingReviewer and reviewing only for one with reviewers, so every other
// config's report renders as it did before those stages.
function counts(issues, syncState, live, cfg, verifying = 0, reviewing = 0) {
  const labelOf = i => (i.labels || []).find(l => l.startsWith('cell:')) || null;
  const open = issues.filter(i => String(i.state).toUpperCase() === 'OPEN');
  const n = l => open.filter(i => labelOf(i) === l).length;
  const merged = issues.filter(i => labelOf(i) === 'cell:merged').length;
  const inFlight = n('cell:active') + open.filter(i => labelOf(i) === 'cell:queued' && (i.labels || []).some(l => l.startsWith('worker:'))).length;
  const c = { open: open.length, queued: n('cell:queued'), active: n('cell:active'), awaitingReview: n('cell:awaiting-review'), blocked: n('cell:blocked'), merged, live: live.length, wipCap: cfg.wipCap, wipFree: Math.max(0, cfg.wipCap - inFlight) };
  if ((cfg.targets || []).some(t => t.verify)) { c.awaitingLab = n('cell:awaiting-lab'); c.verifying = verifying; }
  if ((cfg.reviewers || []).length) { c.awaitingReviewer = n('cell:awaiting-reviewer'); c.reviewing = reviewing; }
  return c;
}

function runCycle(cfg, { apply = false, log = () => {} } = {}) {
  const store = new Store(cfg.stateDir);
  const tracker = new Tracker(cfg.bins);
  const id = cycleId();
  const at = new Date().toISOString();
  const r = { cycleId: id, at, dryRun: !apply, outcome: null, movement: [], counts: {}, alarms: [], launched: [], reaped: [], escalations: [], parked: [], promoted: [], assigned: [], held: [], verify: [], review: [], merge: [], sync: null, streak: 0, latched: null };
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
    // A target whose review policy (read by the sync from its manifest) has no
    // reviewer to meet it is a config that fails validation: nothing runs.
    try { requireReviewers(cfg, sync.state.reviewPolicies || {}); }
    catch (e) {
      if (e.code !== 'ECONFIG') throw e;
      alarm('config-invalid', e.message);
      r.outcome = 'alarm';
      return { report: r, exit: EXIT.usage };
    }
    // With coordinators set, fleet's own login must be one: sync, assign and
    // promote write coordinator labels as it. Read once, before promote.
    if (cfg.coordinators.length) {
      const me = tracker.login();
      if (!me.ok) { alarm('login-failed', `gh api user: ${me.error}; with coordinators set, fleet cannot tell its own label writes from another account's`); r.outcome = 'alarm'; return { report: r, exit: EXIT.internal }; }
      try { requireFleetCoordinator(cfg, me.login); }
      catch (e) {
        if (e.code !== 'ECONFIG') throw e;
        alarm('config-invalid', e.message);
        r.outcome = 'alarm';
        return { report: r, exit: EXIT.usage };
      }
    }
    for (const row of r.sync.changes) {
      if (row.to === 'cell:merged') r.movement.push({ package: scope.packageId((sync.state.issues.find(i => i.number === row.number) || {}).title) || `#${row.number}`, issue: row.number, artifact: { type: 'merged', ref: row.why } });
    }

    // Fresh issue list with bodies: promotion and launch read SCOPE.json from it.
    const list = tracker.listIssues(cfg.repo);
    if (!list.ok) { alarm('issues-failed', list.error); r.outcome = 'alarm'; return { report: r, exit: list.truncated ? EXIT.truncated : EXIT.internal }; }
    // The epic's packages only, matching the sync's --epic: promotion, launch,
    // reap and the counts never act on another program in the same host repo.
    const epicIssues = list.issues.filter(i => scope.partOf(i.body) === cfg.epic);

    // 1b. provenance: a package whose agent-ready, cell:* or worker:* came from
    // an account not in coordinators, or whose timeline cannot be read, is
    // held: no promote, assign, launch, re-dispatch, review or merge. It stays
    // in the counts, and in the assign state without cell:queued, so a held
    // cell:active package still holds a WIP slot (a held cell:queued one does not).
    const foreignHeld = new Set();
    if (cfg.coordinators.length) {
      const pv = provenance.foreign(cfg, epicIssues, tracker);
      const refusal = 'fleet will not promote, assign, launch, re-dispatch, review or merge it';
      for (const f of pv.flagged) {
        alarm('label-foreign-actor', `${f.id} #${f.number}: ${f.label} applied by ${f.actor === null ? 'an unknown account (no labeled event by a known login)' : f.actor}, not a coordinator (${cfg.coordinators.join(', ')}); ${refusal}`, f.number);
        foreignHeld.add(f.number);
      }
      for (const e of pv.errors) {
        alarm('label-actors-failed', `${e.id} #${e.number}: the timeline read failed (${String(e.error).split('\n')[0]}); an unread provenance is not trusted, so ${refusal}`, e.number);
        foreignHeld.add(e.number);
      }
    }
    const trusted = i => !foreignHeld.has(i.number);
    const issues = epicIssues.filter(trusted);
    // What verify, review and merge read: the sync's state and rows without the held packages.
    const syncTrusted = foreignHeld.size
      ? { ...sync, rows: sync.rows.filter(x => !foreignHeld.has(x.number)), state: { ...sync.state, issues: sync.state.issues.filter(trusted) } }
      : sync;

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
    // A held package stays in, so an in-flight one still counts toward
    // wipCap, but without cell:queued, so it is never a candidate.
    const assignIssues = epicIssues.map(i => (trusted(i) ? i : { ...i, labels: i.labels.filter(l => l !== 'cell:queued') }));
    const asg = scripts.runAssign(cfg, { apply, issues: assignIssues });
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
    const pullsFailed = new Set();
    for (const t of cfg.targets) { const p = tracker.listPulls(t.repo); if (p.ok) pulls.push(...p.pulls.map(x => ({ ...x, repo: t.repo }))); else { alarm('pulls-failed', p.error); pullsFailed.add(t.repo); } }
    const reaped = reapMod.reap(cfg, state, pulls, Date.now(), s => { const x = synced.get(s.issue); return Boolean(x && x.blockerOnBranch); });
    r.reaped = reaped.reaped;
    for (const x of reaped.reaped) {
      if (x.outcome === 'pr') r.movement.push({ package: x.id, issue: x.issue, artifact: { type: 'pr', ref: x.artifact.ref, detail: x.detail } });
      if (x.outcome === 'parked') { r.parked.push(x); if (x.alarm) alarm('blocker-overdue', x.alarm, x.issue); }
      // A worker killed from outside (no exit file) is never movement: its
      // relaunch below is reported here and not as a dispatch.
      if (x.outcome === 'vanished') {
        const held = x.reason === 'worker-vanished-repeat';
        alarm(held ? 'worker-vanished-repeat' : 'worker-vanished', `${x.id} ${x.detail}${held ? '' : `; relaunching at attempt ${x.attempt}`}`, x.issue);
      }
    }

    // FLEET_ONLY_ISSUE narrows `fleet launch <issue>` to one package without a
    // second launch path. It launches only, so it runs no verify stage.
    const only = process.env.FLEET_ONLY_ISSUE ? Number(process.env.FLEET_ONLY_ISSUE) : null;

    // 4b. verify: one run in flight per verify target; a failure's re-dispatch
    // joins this cycle's launch requests below. It reads the sync without the
    // held packages, as review and merge do, so a held package's PR is neither
    // posted nor retitled. A run in flight for a held package is set aside:
    // the stage neither reads nor stamps it, and the record is judged once a
    // coordinator's labels are back. Its target posts nothing new while it is
    // set aside (the run still holds the lab), but the stage still retitles the
    // target's trusted PRs. One exception: a finished run that did not revert
    // the lab is not set aside, so the stage latches the fleet on it (that
    // path writes nothing to the PR). A status fetch that fails raises
    // verify-unreachable, as the stage does for an unheld run, and the record
    // is kept and set aside all the same.
    const verifyHeld = [];
    if (only === null && foreignHeld.size) {
      for (const t of cfg.targets) {
        if (!t.verify || t.verify.kind === 'manual') continue;
        const vs = state.verify && state.verify[t.repo];
        const f = vs && vs.inFlight;
        if (!f || !foreignHeld.has(f.issue)) continue;
        const base = String(t.verify.url).replace(/\/+$/, '');
        const g = verifyMod.request('GET', `${base}/runs/${encodeURIComponent(f.runId)}`);
        const rec = g.ok && g.status === 200 && g.json && typeof g.json === 'object' ? g.json : null;
        if (!rec) alarm('verify-unreachable', `${g.ok ? `GET ${base}/runs/${f.runId} answered ${g.status}` : g.error}; run ${f.runId} for PR #${f.pr} is kept`, f.issue);
        if (rec && rec.finishedAt && (rec.verify || {}).reverted !== true) continue;
        verifyHeld.push({ repo: t.repo, vs, f });
        vs.inFlight = null;
        r.verify.push({ target: t.repo, pr: f.pr, action: 'held', detail: `run ${f.runId}: label-foreign-actor on #${f.issue}; its result waits` });
      }
    }
    // The held targets' queues are left out, so nothing is posted in their slot.
    const heldRepos = new Set(verifyHeld.map(h => h.repo));
    const verifySync = heldRepos.size
      ? (() => {
        const inHeld = new Set(syncTrusted.state.issues.filter(i => heldRepos.has(i.repo)).map(i => i.number));
        return { ...syncTrusted, rows: syncTrusted.rows.filter(x => !(x.to === 'cell:awaiting-lab' && inHeld.has(x.number))) };
      })()
      : syncTrusted;
    let vr;
    try {
      vr = only === null
        ? verifyMod.stage({ cfg, state, apply, tracker, pulls, pullsFailed, sync: verifySync, issues, at, alarm, r })
        : { requests: [], verifying: verifyMod.inFlightCount(cfg, state), waiting: verifyMod.manualWaiting(cfg, syncTrusted), latched: false };
    } finally {
      for (const h of verifyHeld) h.vs.inFlight = h.f;
    }
    vr.verifying += verifyHeld.length;
    reaped.requests.push(...vr.requests);

    // 4c. review: one reviewer in flight per cell:awaiting-reviewer PR; a
    // fail's re-dispatch takes the verify-failed path below. A fleet the
    // verify stage just latched starts no reviewer either.
    // A reviewer already running on a held package is set aside: the stage
    // neither judges its verdict nor stamps its PR. The record is kept, and
    // judged once a coordinator's labels are back.
    const reviewsHeld = [];
    if (foreignHeld.size) {
      for (const [repo, rs] of Object.entries(state.review || {})) {
        const list = (rs && rs.inFlight) || [];
        const held = list.filter(f => foreignHeld.has(f.issue));
        if (!held.length) continue;
        rs.inFlight = list.filter(f => !foreignHeld.has(f.issue));
        reviewsHeld.push({ rs, held });
        for (const f of held) r.review.push({ target: repo, pr: f.pr, action: 'held', detail: `${f.reviewer}: label-foreign-actor on #${f.issue}; its verdict waits` });
      }
    }
    let rv;
    try {
      rv = only === null && !vr.latched
        ? reviewMod.stage({ cfg, state, apply, tracker, pulls, pullsFailed, sync: syncTrusted, issues, at, alarm, r })
        : { requests: [], reviewing: reviewMod.inFlightCount(cfg, state) };
    } finally {
      for (const { rs, held } of reviewsHeld) rs.inFlight.push(...held);
    }
    rv.reviewing += reviewsHeld.reduce((n, x) => n + x.held.length, 0);
    reaped.requests.push(...rv.requests);

    // 4c'. rework: a person's `REWORK: <who> @ <head>` on a package PR sends
    // its worker back through the same review-failed path (src/rework.js).
    if (only === null && !vr.latched) {
      const rw = reworkMod.stage({ cfg, state, apply, pulls, pullsFailed, sync: syncTrusted, alarm, r, pending: reaped.requests });
      reaped.requests.push(...rw.requests);
    }

    // 4d. merge: each autoMerge target's PRs that meet the merge condition go
    // into its integration branch; a protected base is refused. Not when the
    // verify stage latched the fleet.
    if (only === null && !vr.latched) mergeMod.stage({ cfg, apply, tracker, pulls, pullsFailed, sync: syncTrusted, alarm, r });

    // 5. launch: owned, queued, labeled packages without a session; plus relaunch/escalation requests.
    const persist = rec => { state.sessions[rec.issue] = rec; if (apply) store.save(state); };
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
      // A held package's re-dispatch waits, like one without agent-ready, and
      // goes ahead once a coordinator's labels are back.
      if (foreignHeld.has(s.issue)) {
        s.status = 'retry'; s.retry = { next: q.next, reason: q.reason, why: 'label-foreign-actor' };
        r.held.push({ number: s.issue, id: s.id, why: 'label-foreign-actor' });
        continue;
      }
      const iss = issues.find(i => i.number === s.issue);
      if (!iss) continue;
      // A package without agent-ready is the coordinator's: no re-dispatch of
      // any kind (unpark, verify or review failure, escalation, relaunch).
      // The request is kept for retry and goes ahead once the label is back.
      if (!iss.labels.includes('agent-ready')) {
        s.status = 'retry'; s.retry = { next: q.next, reason: q.reason, why: 'agent-ready removed' };
        r.held.push({ number: s.issue, id: s.id, why: `re-dispatch (${q.next}, ${q.reason}) held: no agent-ready label` });
        continue;
      }
      const d = scope.describe(iss);
      if (d.problems.length) { alarm('unlaunchable', d.problems.join('; '), s.issue); s.status = 'retry'; s.retry = { next: q.next, reason: q.reason, why: d.problems.join('; ') }; continue; }
      const prior = state.dispatches[s.id] || [];
      if (q.next === 'unpark') {
        requests.push({ issue: iss, id: s.id, sc: d.scope, workerId: s.worker, attempt: s.attempt + 1, tier: s.tier, reason: 'unparked', from: s, next: 'unpark' });
        dispatchable += 1;
        continue;
      }
      // A verification or review failure sends the worker back at the same
      // tier; it counts toward maxEscalations like any other re-dispatch.
      if (q.next === 'verify-failed' || q.next === 'review-failed') {
        const escalations = Math.max(0, prior.length - 1);
        if (escalations >= cfg.maxEscalations) { alarm('escalation-cap', `${s.id} has been re-dispatched ${escalations} time(s); last: ${q.reason}. Holding.`, s.issue); continue; }
        requests.push({ issue: iss, id: s.id, sc: d.scope, workerId: s.worker, attempt: s.attempt + 1, tier: s.tier, reason: q.reason, from: s, next: q.next });
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

    // A lab the verify stage found unreverted latched the fleet: nothing
    // launches. Re-dispatches are kept for retry after `fleet resume`.
    if (vr.latched) {
      for (const q of requests) if (q.from) { q.from.status = 'retry'; q.from.retry = { next: q.next, reason: q.reason, why: 'latched: verify-not-reverted' }; }
      requests.length = 0;
      dispatchable = 0;
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
      const vanishedRelaunch = q.reason === 'worker-vanished';
      // A vanished relaunch held over from an earlier cycle (wip-cap, a failed
      // launch) is named here, so no launch in this report goes unexplained.
      if (vanishedRelaunch && q.from && q.from.status === 'retry') alarm('worker-vanished', `${q.id} relaunched at attempt ${q.attempt}, held since it vanished (${q.from.retry.why})`, q.issue.number);
      if (q.from && q.from.status === 'retry') { q.from.status = 'closed'; delete q.from.retry; }
      slots -= 1;
      r.launched.push({ issue: q.issue.number, id: q.id, worker: q.workerId, mode: out.session.mode, tier: q.tier, attempt: q.attempt, branch: q.sc.branch, worktree: out.session.worktree, pid: out.session.pid || null, adopted: Boolean(out.adopted), recut: Boolean(out.recut), ci: out.session.ci || null, standards: out.session.standards || null });
      // A relaunch repeats a dispatch rather than adding one, except when the
      // original's record was lost to a crash before it was written.
      if (!state.dispatches[q.id]) state.dispatches[q.id] = [];
      if (!q.relaunch || state.dispatches[q.id].length < q.attempt) {
        state.dispatches[q.id].push({ n: q.attempt, tier: q.tier, reason: q.reason, runId: out.session.sessionId || null, ts: at, recovered: Boolean(q.relaunch) || undefined });
      }
      if (vanishedRelaunch) r.launched[r.launched.length - 1].vanished = true;
      if (!out.dryRun && !vanishedRelaunch) r.movement.push({ package: q.id, issue: q.issue.number, artifact: { type: 'dispatch', ref: q.sc.branch, detail: `attempt ${q.attempt}` } });
    }

    // 6. outcome, streak, latch
    const liveAfter = reaped.live.length + r.launched.filter(l => l.pid).length;
    // A worker relaunched after vanishing is not evidence of progress, so it
    // does not hold the streak down; if it survives, the next cycle sees it live.
    const liveForStreak = reaped.live.length + r.launched.filter(l => l.pid && !l.vanished).length;
    r.counts = counts(epicIssues, sync.state, { length: liveAfter }, cfg, vr.verifying, rv.reviewing);
    // Faults that make the cycle an alarm when nothing moved. A WIP-cap hold
    // is not one: a full fleet with nothing else to do is exhaustion.
    const FAULT = /(-failed$|^locked$|^latched$|^escalation-cap$|^launch-|^unlaunchable$|^worker-vanished(-repeat)?$|^verify-(unreachable|refused|not-reverted|bad-sha)$)/;
    // A verify or review fault is an alarm even beside movement: each one
    // needs a look (a lab not reverted, a verifier that cannot be reached, a
    // refused PR, a record that cannot be stamped, a reviewer that wrote,
    // timed out or gave no verdict). A stale result is not one: the PR waits again.
    // A refused protected merge is one too: a PR aimed at a protected branch.
    // So is a package held for its label provenance: a person has to look.
    const VERIFY_FAULT = /^((verify|review)-(?!stale$)|merge-protected-refused$|label-(foreign-actor|actors-failed)$)/;
    if (r.alarms.some(a => VERIFY_FAULT.test(a.code))) r.outcome = 'alarm';
    else if (r.alarms.some(a => FAULT.test(a.code)) && r.movement.length === 0) r.outcome = 'alarm';
    else if (r.movement.length) r.outcome = 'movement';
    else if (dispatchable > 0 && r.launched.length === 0) r.outcome = 'alarm';
    else r.outcome = 'exhaustion';
    if (r.outcome === 'alarm' && !r.alarms.length) alarm('no-movement', `${dispatchable} package(s) were dispatchable and none launched`);

    if (apply) {
      // A verifier run in flight is live work: waiting on it is not idleness.
      // So is a manual target's queue: its verifier is outside fleet. So is a
      // reviewer in flight.
      if (r.outcome === 'movement') state.streak = 0;
      else if (liveForStreak === 0 && vr.verifying === 0 && vr.waiting === 0 && rv.reviewing === 0) state.streak += 1;
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
