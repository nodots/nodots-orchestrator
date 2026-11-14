'use strict';

/*
 * Reaping: what happened to each launched session, and what the cycle does
 * about it. Liveness and timeouts are decided here; the rest is a pure
 * classification over observable facts (exit file, BLOCKER.md, the PR list),
 * so the table in the plan has one fixture per row.
 *
 * Nothing here reads HANDOFF.md for routing, runs git stash, or edits a
 * SCOPE.json. A session that filed a BLOCKER.md with a Kind is parked for the
 * coordinator, not relaunched: a tier change cannot clear a tracked-task or a
 * not-before. (This is a documented deviation from coordination.md.)
 */

const fs = require('fs');
const path = require('path');
const { isAlive, processStart, signal } = require('./exec');
const scope = require('./scope');

const KINDS = new Set(['tracked-task', 'human-decision', 'external', 'foreign-lease', 'not-before']);

function readExit(exitPath) {
  try { const t = fs.readFileSync(exitPath, 'utf8').trim(); return t === '' ? null : Number(t); } catch { return null; }
}

function blockerFor(session) {
  const candidates = [
    path.join(session.worktree, 'BLOCKER.md'),
    path.join(session.worktree, '.agentic', 'cells', ...String(session.branch).split('/'), 'BLOCKER.md'),
  ];
  for (const p of candidates) {
    if (!fs.existsSync(p)) continue;
    const text = fs.readFileSync(p, 'utf8');
    // Accepts "Kind: x", "**Kind:** x" and "**Kind**: x", as a line or a bullet.
    const field = name => new RegExp(`^\\s*(?:[-*]\\s*)?\\**(?:${name})\\**\\s*:?\\s*\\**\\s*:?\\s*(.+?)\\s*$`, 'im');
    const grab = name => { const m = field(name).exec(text); return m ? m[1].replace(/^`|`$/g, '').trim() : null; };
    const kind = (grab('Kind') || '').toLowerCase().replace(/[^a-z-].*$/, '') || null;
    const ask = grab('Ask|One-line ask|Un-?blocks? when');
    // A date on any of these fields; the first one that is a date wins.
    let notBefore = null;
    for (const name of ['Not before', 'Decide by', 'Reference']) {
      const v = grab(name);
      if (v && /^\d{4}-\d{2}-\d{2}/.test(v)) { notBefore = v.split(/\s/)[0]; break; }
    }
    return { path: p, kind, known: KINDS.has(kind), ask: ask ? ask.trim() : null, notBefore };
  }
  return null;
}

// A PR belongs to a package only when its head branch equals the package
// branch. A title or closing keyword is not evidence: a throwaway PR carrying
// the package id would otherwise be recorded as the package's PR.
function prFor(session, pulls) {
  return (pulls || []).find(p => p.headRefName === session.branch) || null;
}

// classify(session, facts) -> { outcome, detail, next }
//   outcome: pr | parked | escalate | relaunch | vanished
//   next:    'escalate' | 'relaunch' | null
// Pure: facts = { exitCode, blocker, pr, logEmpty, livedMs, lastWriteMs, logBytes }
//   livedMs:     launch to now, the most the process can have lived
//   lastWriteMs: launch to its last log write, the least it lived (0 if none)
//   logBytes:    what this run wrote to the log
//
// vanished: the record reached `running`, so a process was spawned, and the
// launcher's wrapper writes the exit file on every exit it lives through
// (src/exec.js spawnDetached). No exit file means the wrapper was killed too:
// a supervisor killing its control group, a reboot. A timeout kill also takes
// the wrapper (signal() targets the process group), so a session reap killed
// on timeout is classified by the timeout row, not here.
function classify(session, facts) {
  if (facts.pr) {
    const draft = facts.pr.isDraft ? ' (draft)' : '';
    return { outcome: 'pr', detail: `PR #${facts.pr.number}${draft} ${facts.pr.state}`, next: null, artifact: { type: 'pr', ref: facts.pr.number, state: facts.pr.state } };
  }
  if (facts.blocker) {
    if (facts.blocker.known) {
      const past = facts.blocker.notBefore && Date.parse(facts.blocker.notBefore) < Date.now();
      return { outcome: 'parked', detail: `BLOCKER.md kind=${facts.blocker.kind}${facts.blocker.ask ? `: ${facts.blocker.ask}` : ''}`, next: null, alarm: past ? `BLOCKER kind=${facts.blocker.kind} date ${facts.blocker.notBefore} has passed` : null, kind: facts.blocker.kind };
    }
    return { outcome: 'escalate', detail: `BLOCKER.md without a recognized Kind (${facts.blocker.kind || 'none'})`, next: 'escalate', reason: 'blocker:none' };
  }
  if (session.status === 'running' && session.pid && !session.killedAt && facts.exitCode === null) {
    const livedSeconds = Math.max(0, Math.round((facts.livedMs || 0) / 1000));
    const livedMinSeconds = Math.min(livedSeconds, Math.max(0, Math.round((facts.lastWriteMs || 0) / 1000)));
    const logBytes = facts.logBytes || 0;
    return {
      outcome: 'vanished', next: 'relaunch', reason: 'worker-vanished',
      detail: `pid ${session.pid} gone with no exit file; lived ${livedMinSeconds}s to ${livedSeconds}s (last log write to reap); log ${logBytes} bytes`,
      vanished: { pid: session.pid, livedSeconds, livedMinSeconds, logBytes },
    };
  }
  if (session.status === 'launching' || (facts.logEmpty && facts.exitCode === null)) {
    return { outcome: 'relaunch', detail: 'process never ran (crash before or at spawn)', next: 'relaunch', reason: 'crash-before-run' };
  }
  if (facts.exitCode === 0) return { outcome: 'escalate', detail: 'exit 0 with no PR and no BLOCKER.md', next: 'escalate', reason: 'silent' };
  if (facts.exitCode === 143 || session.killedAt) return { outcome: 'escalate', detail: `killed on timeout (exit ${facts.exitCode})`, next: 'escalate', reason: 'timeout' };
  return { outcome: 'escalate', detail: `exit ${facts.exitCode === null ? 'unknown' : facts.exitCode} with no PR and no BLOCKER.md`, next: 'escalate', reason: `exit:${facts.exitCode === null ? 'unknown' : facts.exitCode}` };
}

// reap(cfg, state, pulls, now) -> { live, reaped[], requests[] }
// Mutates session records in state (status, outcome, termSentAt) and
// state.vanished (package id -> [{ at, attempt, logPath, logSize }], one per
// vanishing inside sessionTimeoutMinutes). Does not save; the
// cycle saves once at the end.
function reap(cfg, state, pulls, now = Date.now(), blockerOnBranch = null) {
  const live = [];
  const reaped = [];
  const requests = [];     // { session, next, reason }
  const timeoutMs = cfg.sessionTimeoutMinutes * 60000;
  const graceMs = cfg.killGraceSeconds * 1000;

  for (const session of Object.values(state.sessions)) {
    // A relaunch the last cycle could not make (lane refused, workspace
    // untrusted, push rejected) is asked for again, so a package is never
    // stranded behind a one-time failure.
    if (session.status === 'retry' && session.retry) {
      requests.push({ session, next: session.retry.next, reason: session.retry.reason, retry: true });
      continue;
    }
    // A parked package resumes when the coordinator has recorded the decision
    // and removed BLOCKER.md: no blocker in the worktree and none on the branch
    // head (sync's blockerOnBranch). The relaunch keeps the tier; it is a new
    // dispatch with reason "unparked", not an escalation.
    if (session.status === 'parked') {
      const onBranch = blockerOnBranch ? blockerOnBranch(session) : false;
      if (!blockerFor(session) && !onBranch) {
        // A package that already has a PR, in any state, is not relaunched.
        const pr = prFor(session, pulls);
        if (pr) {
          const c = classify(session, { pr });
          session.status = 'closed'; session.outcome = c.outcome; session.endedAt = new Date(now).toISOString();
          reaped.push({ issue: session.issue, id: session.id, attempt: session.attempt, tier: session.tier, ...c });
          continue;
        }
        session.status = 'closed'; session.outcome = 'unparked'; session.endedAt = new Date(now).toISOString();
        reaped.push({ issue: session.issue, id: session.id, attempt: session.attempt, tier: session.tier, outcome: 'unparked', detail: 'BLOCKER.md removed; resuming', next: 'unpark' });
        requests.push({ session, next: 'unpark', reason: 'unparked' });
      }
      continue;
    }
    if (!['launching', 'running'].includes(session.status)) continue;

    const alive = session.pid && isAlive(session.pid) && (!session.procStart || processStart(session.pid) === session.procStart);
    if (alive) {
      const age = now - Date.parse(session.startedAt);
      if (age > timeoutMs) {
        if (!session.termSentAt) { signal(session.pid, 'SIGTERM'); session.termSentAt = new Date(now).toISOString(); session.killedAt = session.termSentAt; }
        else if (now - Date.parse(session.termSentAt) > graceMs) { signal(session.pid, 'SIGKILL'); }
      }
      live.push({ issue: session.issue, id: session.id, pid: session.pid, ageMinutes: Math.round(age / 60000), timingOut: Boolean(session.termSentAt) });
      continue;
    }

    const log = fs.existsSync(session.logPath) ? fs.statSync(session.logPath) : null;
    const logSize = log ? log.size : 0;
    const started = Date.parse(session.startedAt);
    // A same-attempt relaunch appends to the same log, so this run's bytes are
    // the size now less the size when this attempt last vanished.
    const prior = ((state.vanished || {})[session.id] || []).filter(v => v.attempt === session.attempt && v.logPath === session.logPath).pop();
    const runBytes = Math.max(0, logSize - (prior ? prior.logSize : 0));
    const facts = {
      exitCode: readExit(session.exitPath),
      blocker: blockerFor(session),
      pr: prFor(session, pulls),
      logEmpty: logSize === 0,
      livedMs: now - started,
      lastWriteMs: runBytes > 0 ? log.mtimeMs - started : 0,
      logBytes: runBytes,
    };
    const c = classify(session, facts);
    // Two vanishings of one package inside sessionTimeoutMinutes hold it: a
    // worker that keeps being killed from outside will not be saved by a third
    // launch. The history is keyed by package id because a relaunch replaces
    // the session record.
    if (c.outcome === 'vanished') {
      state.vanished = state.vanished || {};
      const recent = (state.vanished[session.id] || []).filter(v => now - Date.parse(v.at) <= timeoutMs);
      recent.push({ at: new Date(now).toISOString(), attempt: session.attempt, logPath: session.logPath, logSize });
      state.vanished[session.id] = recent;
      if (recent.length >= 2) {
        c.next = null;
        c.reason = 'worker-vanished-repeat';
        c.detail += `; vanished ${recent.length} times within ${cfg.sessionTimeoutMinutes} min, holding`;
      }
    }
    session.status = c.outcome === 'parked' ? 'parked' : 'closed';
    session.outcome = c.outcome;
    session.exitCode = facts.exitCode;
    session.endedAt = new Date(now).toISOString();
    reaped.push({ issue: session.issue, id: session.id, attempt: session.attempt, tier: session.tier, ...c });
    if (c.next) requests.push({ session, next: c.next, reason: c.reason });
  }
  return { live, reaped, requests };
}

module.exports = { reap, classify, blockerFor, prFor, readExit, KINDS };
