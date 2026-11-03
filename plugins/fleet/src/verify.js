'use strict';

/*
 * The verify stage: for each target with `verify` (config.js), keep exactly
 * one verifier run in flight and act on each result. It runs after reap and
 * before launch, so a failure's re-dispatch joins this cycle's launches.
 *
 * The verifier contract (the lab runner, loopback only):
 *   POST <url>/<suite>/verify {"pr": n}
 *     202 {"run":{"id"}}                     the run started
 *     409 {"error":"a run is already going…"} busy: try again next cycle
 *     409 {"error":"<reason>"}               this PR cannot be verified
 *   GET  <url>/runs/<id>
 *     { finishedAt, exitCode, tests: [{title, status, outcome}],
 *       verify: { pr, repo, headSha, base, deployed, selection, reverted } }
 *
 * The only local memory is state.verify[<target repo>]:
 *   inFlight  { pr, runId, headSha, issue, package, postedAt } or null
 *   failed    { <pr>: { headSha, kind: failed|refused|bad-sha, ... } }, so a PR
 *             is not posted again at the head its last run failed or was refused at
 * Which PRs wait is never stored: it is the sync's cell:awaiting-lab, every cycle.
 *
 * Dry run: no POST, no PR comment, no title edit, no latch. A GET is a read and
 * is made, so the report can say what the cycle would do with a finished run.
 */

const path = require('path');
const { run } = require('./exec');
const scope = require('./scope');
const { mergedBranches } = require('./promote');

const SUITE_LABEL = 'lab-impacted';
const SHA = /^[0-9a-f]{40}$/;
const BUSY = /^a run is already going/;
const GATE = /^V\d+$/;
const HTTP_TIMEOUT_MS = 20000;

// One HTTP request, synchronously, through a child node: the cycle is
// synchronous end to end. -> { ok:true, status, json, text } | { ok:false, error }
const FETCH = `
const [m, u, b] = process.argv.slice(1);
fetch(u, { method: m, headers: b ? { 'content-type': 'application/json' } : {}, body: b || undefined, signal: AbortSignal.timeout(${HTTP_TIMEOUT_MS}) })
  .then(async r => { process.stdout.write(JSON.stringify({ status: r.status, text: await r.text() })); })
  .catch(e => { process.stderr.write(String((e && e.cause && (e.cause.code || e.cause.message)) || (e && e.message) || e)); process.exit(2); });
`;
function request(method, url, body) {
  const args = ['-e', FETCH, method, url];
  if (body !== undefined) args.push(JSON.stringify(body));
  const r = run(process.execPath, args, { timeoutMs: HTTP_TIMEOUT_MS + 5000 });
  if (r.status !== 0) return { ok: false, error: `${method} ${url}: ${r.error || r.stderr.trim() || `exit ${r.status}`}` };
  let o;
  try { o = JSON.parse(r.stdout); } catch (e) { return { ok: false, error: `${method} ${url}: unreadable response (${e.message})` }; }
  let json = null;
  try { json = JSON.parse(o.text); } catch { /* not JSON; the text is kept */ }
  return { ok: true, status: o.status, json, text: o.text };
}

const short = sha => (typeof sha === 'string' ? sha.slice(0, 7) : String(sha));
const oneLine = s => String(s === undefined || s === null ? '' : s).replace(/\s+/g, ' ').trim().slice(0, 200);
const isOpen = p => Boolean(p) && String(p.state).toUpperCase() === 'OPEN';

// The summary under a stamp or a failure: the count by outcome, each
// unexpected or flaky test by title, and the selection and deployed set as
// the record carries them. Every line starts with a word other than VERIFIED,
// so a test title can never forge a stamp line.
function summary(rec) {
  const tests = Array.isArray(rec.tests) ? rec.tests : [];
  const by = {};
  for (const t of tests) { const o = oneLine((t && t.outcome) || 'unknown'); by[o] = (by[o] || 0) + 1; }
  const keys = Object.keys(by).sort();
  const lines = [`tests: ${keys.length ? keys.map(k => `${k} ${by[k]}`).join(', ') : 'none recorded'}`];
  for (const t of tests) if (t && (t.outcome === 'unexpected' || t.outcome === 'flaky')) lines.push(`- ${t.outcome}: ${oneLine(t.title)}`);
  const v = rec.verify || {};
  if (v.selection !== undefined) lines.push(`selection: ${JSON.stringify(v.selection)}`);
  if (v.deployed !== undefined) lines.push(`deployed: ${JSON.stringify(v.deployed)}`);
  return lines.join('\n');
}

function slot(state, repo) {
  state.verify = state.verify || {};
  const vs = state.verify[repo] || { inFlight: null, failed: {} };
  vs.failed = vs.failed || {};
  state.verify[repo] = vs;
  return vs;
}

// Runs recorded in flight across every verify target, without asking anyone.
function inFlightCount(cfg, state) {
  return cfg.targets.filter(t => t.verify && state.verify && state.verify[t.repo] && state.verify[t.repo].inFlight).length;
}

// stage(ctx) -> { requests: [{ session, next: 'verify-failed', reason }], verifying, latched }
// ctx: { cfg, state, apply, tracker, pulls, pullsFailed (Set of repos), sync, issues, at, alarm, r, http? }
// Mutates state.verify, state.latched (apply only) and r (verify notes, movement).
function stage({ cfg, state, apply, tracker, pulls, pullsFailed = new Set(), sync, issues, at, alarm, r, http = request }) {
  const out = { requests: [], verifying: 0, latched: false };
  const targets = cfg.targets.filter(t => t.verify);
  if (!targets.length) return out;
  const { currentStamp } = require(path.join(cfg.scriptsDir, 'stamp.js'));
  const synced = (sync.state && sync.state.issues) || [];
  const awaiting = new Set((sync.rows || []).filter(x => x.to === 'cell:awaiting-lab').map(x => x.number));
  const merged = mergedBranches(sync.state);

  for (const t of targets) {
    if (out.latched) break;
    const vs = slot(state, t.repo);
    const base = String(t.verify.url).replace(/\/+$/, '');
    const acted = new Set();
    const note = (pr, action, detail) => r.verify.push({ target: t.repo, pr, action, detail });
    const prOf = n => pulls.find(p => p.repo === t.repo && p.number === n) || null;
    const pkgOf = n => synced.find(i => i.pr && i.pr.number === n && i.repo === t.repo) || null;
    const idOf = si => (si ? scope.packageId(si.title) || `#${si.number}` : null);

    // Without this target's PR list nothing here can be judged: a finished
    // result would read as a closed PR. The record is kept for next cycle.
    if (pullsFailed.has(t.repo)) {
      if (vs.inFlight) out.verifying += 1;
      note(vs.inFlight ? vs.inFlight.pr : '-', 'skipped', 'the PR list for this target failed (pulls-failed)');
      continue;
    }

    // The title follows the stamp. A push after [READY] voids the stamp, so
    // the PR goes back to the queue as [VERIFY]:; a [VERIFY]: PR whose head
    // carries a current stamp (a retitle that failed, or a comment read that
    // came back empty last cycle) goes to [READY]:.
    for (const si of synced) {
      if (!si.pr || si.repo !== t.repo) continue;
      const p = prOf(si.pr.number);
      if (!isOpen(p)) continue;
      const ready = /^\[READY\]:/.test(String(p.title || ''));
      if (!ready && !/^\[VERIFY\]:/.test(String(p.title || ''))) continue;
      const stamped = Boolean(currentStamp({ headSha: p.headRefOid, comments: si.pr.comments || [] }));
      if (ready === stamped) continue;
      const title = ready ? String(p.title).replace(/^\[READY\]:/, '[VERIFY]:') : String(p.title).replace(/^\[VERIFY\]:/, '[READY]:');
      const why = ready ? `no stamp at head ${short(p.headRefOid)}` : `stamped at head ${short(p.headRefOid)}`;
      acted.add(p.number);
      if (!apply) { note(p.number, ready ? 'would-requeue' : 'would-retitle-ready', why); continue; }
      const w = tracker.editPrTitle(t.repo, p.number, title);
      if (!w.ok) { alarm('verify-write-failed', `retitle of ${t.repo}#${p.number} to ${title.split(' ')[0]} failed: ${w.error}`, si.number); continue; }
      p.title = title;
      note(p.number, ready ? 'requeued' : 'retitled-ready', `${why}; retitled ${title.split(' ')[0]}`);
    }

    // The run in flight: unfinished, leave it; unreachable, keep it; finished, act.
    if (vs.inFlight) {
      const f = vs.inFlight;
      const g = http('GET', `${base}/runs/${encodeURIComponent(f.runId)}`);
      if (!g.ok || g.status !== 200 || !g.json || typeof g.json !== 'object') {
        alarm('verify-unreachable', `${g.ok ? `GET ${base}/runs/${f.runId} answered ${g.status}` : g.error}; run ${f.runId} for PR #${f.pr} is kept`, f.issue);
        out.verifying += 1;
        continue;
      }
      if (!g.json.finishedAt) { out.verifying += 1; note(f.pr, 'running', `run ${f.runId} at ${short(f.headSha)}`); continue; }
      vs.inFlight = null;
      acted.add(f.pr);
      act({ t, f, rec: g.json });
      if (out.latched) break;
      if (vs.inFlight) { out.verifying += 1; continue; }   // a write failed; the result is read again next cycle
    }

    // The next PR: gates first, then packages whose dependencies merged, then oldest.
    const cands = [];
    for (const si of synced) {
      if (!awaiting.has(si.number) || !si.pr || si.repo !== t.repo) continue;
      const p = prOf(si.pr.number);
      if (!isOpen(p) || acted.has(p.number)) continue;
      const last = vs.failed[p.number];
      if (last && last.headSha === p.headRefOid) { note(p.number, 'held', `last run ${last.kind} at this head ${short(p.headRefOid)}`); continue; }
      const iss = issues.find(i => i.number === si.number);
      const ex = iss ? scope.extract(iss.body) : { scope: null };
      const deps = ex.scope && Array.isArray(ex.scope.dependsOn) ? ex.scope.dependsOn : null;
      const id = idOf(si);
      const rank = GATE.test(id) ? 0 : deps && deps.every(b => merged.has(b)) ? 1 : 2;
      cands.push({ si, p, id, rank });
    }
    cands.sort((a, b) => a.rank - b.rank || a.p.number - b.p.number);

    for (const c of cands) {
      const pr = c.p.number;
      if (!apply) { note(pr, 'would-post', `${c.id} at ${short(c.p.headRefOid)}`); break; }
      const res = http('POST', `${base}/${encodeURIComponent(t.verify.suite)}/verify`, { pr });
      if (!res.ok) { alarm('verify-unreachable', `${res.error}; PR #${pr} stays queued`, c.si.number); break; }
      if (res.status === 202) {
        const runId = res.json && res.json.run && res.json.run.id;
        if (typeof runId !== 'string' || !runId) { alarm('verify-post-failed', `POST for PR #${pr} answered 202 without run.id: ${oneLine(res.text)}`, c.si.number); break; }
        vs.inFlight = { pr, runId, headSha: c.p.headRefOid, issue: c.si.number, package: c.id, postedAt: at };
        out.verifying += 1;
        note(pr, 'posted', `${c.id}: run ${runId} at ${short(c.p.headRefOid)}`);
        break;
      }
      const err = oneLine((res.json && res.json.error) || res.text);
      if (res.status === 409 && BUSY.test(err)) { note(pr, 'busy', err); break; }
      if (res.status === 409) {
        vs.failed[pr] = { headSha: c.p.headRefOid, kind: 'refused', error: err, at };
        const w = tracker.prComment(t.repo, pr, `The lab verifier refused this PR at ${c.p.headRefOid}:\n\n${err}\n\nIt is not posted again until the head changes.`);
        if (!w.ok) alarm('verify-write-failed', `refusal comment on ${t.repo}#${pr} failed: ${w.error}`, c.si.number);
        alarm('verify-refused', `PR #${pr} (${c.id}) at ${short(c.p.headRefOid)}: ${err}`, c.si.number);
        note(pr, 'refused', err);
        continue;
      }
      alarm('verify-post-failed', `POST for PR #${pr} answered ${res.status}: ${err}`, c.si.number);
      break;
    }

    function act({ t, f, rec }) {
      const v = rec.verify || {};
      const p = prOf(f.pr);
      const si = pkgOf(f.pr);
      const id = f.package || idOf(si) || `PR #${f.pr}`;
      const issue = f.issue || (si && si.number);
      const ran = v.headSha;

      // A lab that was not put back holds this change for the next run: stop everything.
      if (v.reverted !== true) {
        alarm('verify-not-reverted', `run ${f.runId} for ${t.repo}#${f.pr} finished with verify.reverted ${JSON.stringify(v.reverted)}; nothing launches or verifies until \`fleet resume --reason <text>\``, issue);
        if (apply) state.latched = { at, streak: state.streak, reason: `verify-not-reverted: run ${f.runId} for ${t.repo}#${f.pr} did not revert the lab` };
        out.latched = true;
        note(f.pr, 'not-reverted', `run ${f.runId}`);
        return;
      }
      // A PR missing from the list (one past the page limit) is not a closed
      // one: keep the record and read the result again next cycle.
      if (!p) { vs.inFlight = f; alarm('verify-pr-missing', `run ${f.runId} finished, but PR #${f.pr} is not in the PR list of ${t.repo}; the record is kept`, issue); return; }
      if (!isOpen(p)) { alarm('verify-stale', `run ${f.runId}: PR #${f.pr} is ${p.state}, not open; the result is discarded`, issue); note(f.pr, 'stale', `PR ${p.state}`); return; }
      // The full sha is required to stamp. A failure is acted on without it,
      // at the head the run was posted for.
      const shaOk = typeof ran === 'string' && SHA.test(ran);
      if (!shaOk && rec.exitCode === 0) {
        alarm('verify-bad-sha', `run ${f.runId} for PR #${f.pr} reports verify.headSha ${JSON.stringify(ran)}, not a full 40-character lowercase sha; not stamped`, issue);
        vs.failed[f.pr] = { headSha: f.headSha, kind: 'bad-sha', runId: f.runId, at };
        note(f.pr, 'bad-sha', `verify.headSha ${JSON.stringify(ran)}`);
        return;
      }
      if (f.headSha !== p.headRefOid || (shaOk && ran !== p.headRefOid)) {
        alarm('verify-stale', `run ${f.runId} verified ${short(ran)} (posted at ${short(f.headSha)}), PR #${f.pr} head is now ${short(p.headRefOid)}; the result is discarded and the PR stays queued`, issue);
        note(f.pr, 'stale', `verified ${short(ran)}, head ${short(p.headRefOid)}`);
        return;
      }

      if (rec.exitCode === 0) {
        if (!apply) { note(f.pr, 'would-stamp', `${id} at ${short(ran)}`); return; }
        const c = tracker.prComment(t.repo, f.pr, `VERIFIED: ${SUITE_LABEL} @ ${ran}\n\n${summary(rec)}`);
        if (!c.ok) { vs.inFlight = f; alarm('verify-write-failed', `stamp on ${t.repo}#${f.pr} failed: ${c.error}; the result is read again next cycle`, issue); return; }
        const title = String(p.title || '').replace(/^\[VERIFY\]:/, '[READY]:');
        if (title !== p.title) {
          const e = tracker.editPrTitle(t.repo, f.pr, title);
          if (!e.ok) alarm('verify-write-failed', `retitle of ${t.repo}#${f.pr} to [READY]: failed: ${e.error}; retried next cycle from the stamp`, issue);
          else p.title = title;
        }
        r.movement.push({ package: id, issue, artifact: { type: 'verified', ref: f.pr, detail: `${SUITE_LABEL} @ ${short(ran)}` } });
        note(f.pr, 'verified', `${id} at ${short(ran)}`);
        return;
      }

      const tests = Array.isArray(rec.tests) ? rec.tests : [];
      const first = tests.find(x => x && x.outcome === 'unexpected');
      const reason = `verify-failed: ${first ? oneLine(first.title) : `exitCode ${rec.exitCode}`}`;
      if (!apply) { note(f.pr, 'would-fail', reason); return; }
      const c = tracker.prComment(t.repo, f.pr, `Lab verification failed at ${p.headRefOid} (${SUITE_LABEL}, exitCode ${rec.exitCode}).\n\n${summary(rec)}`);
      if (!c.ok) { vs.inFlight = f; alarm('verify-write-failed', `failure comment on ${t.repo}#${f.pr} failed: ${c.error}; the result is read again next cycle`, issue); return; }
      vs.failed[f.pr] = { headSha: p.headRefOid, kind: 'failed', runId: f.runId, reason, at };
      note(f.pr, 'failed', reason);
      // The worker that opened the PR is sent back at the same tier: a test
      // failure is not a silent worker. The cycle counts it toward maxEscalations.
      const s = issue ? state.sessions[issue] : null;
      if (!s) { alarm('verify-redispatch-failed', `${id}: no session record on this machine, so nobody is re-dispatched; the failure is on the PR`, issue); return; }
      if (s.status !== 'closed') { alarm('verify-redispatch-failed', `${id}: session is ${s.status}, not closed, so it is not re-dispatched; the failure is on the PR`, issue); return; }
      out.requests.push({ session: s, next: 'verify-failed', reason });
    }
  }
  return out;
}

module.exports = { stage, request, summary, inFlightCount, SUITE_LABEL };
