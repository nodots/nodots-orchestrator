'use strict';

/*
 * The rework stage: a person who has read the reviews on a package PR asks for
 * rework by commenting, on the PR,
 *
 *   REWORK: <who> @ <full head sha>
 *
 * on a line of its own. The next cycle sends the worker that opened the PR back
 * at the same tier through the review-failed path (cycle.js), so the
 * re-dispatch is recorded in the dispatch history and counts toward
 * maxEscalations, exactly as a failed machine review does. The reason names who
 * asked, the head, and the PR, and the worker prompt carries it.
 *
 * A marker is current only at the PR's head: a push voids it, as it voids a
 * VERIFIED or REVIEWED stamp. A marker is acted on once per head; the head is
 * recorded in state.rework[<target repo>][<pr>]. The marker carries no author
 * check: like the stamps, anyone who can comment on the PR can post one.
 *
 * It reads every open package PR of the epic, whatever its cell label, because
 * a person's review can arrive after the machine reviewer has stamped.
 *
 * Dry run: nothing is recorded and nothing is requested; the report says what
 * would be sent back.
 */

const scope = require('./scope');

const REWORK = /^REWORK:\s*(\S.*?)\s+@\s+([0-9a-f]{40})\s*$/m;
const short = sha => String(sha).slice(0, 7);
const isOpen = p => Boolean(p) && String(p.state).toUpperCase() === 'OPEN';

// currentRework({ headSha, comments }) -> { who, sha } | null, the first marker at the head.
function currentRework(pr) {
  if (!pr || !pr.headSha) return null;
  const all = new RegExp(REWORK.source, 'gm');
  for (const body of pr.comments || []) {
    for (const m of String(body).matchAll(all)) {
      if (m[2] === pr.headSha) return { who: m[1], sha: m[2] };
    }
  }
  return null;
}

// stage(ctx) -> { requests: [{ session, next: 'review-failed', reason }] }
// ctx: { cfg, state, apply, pulls, pullsFailed, sync, alarm, r, pending }
// pending: the re-dispatch requests already made this cycle, so one session is
// never sent back twice in one pass. Mutates state.rework and r.review.
function stage({ cfg, state, apply, pulls, pullsFailed = new Set(), sync, alarm, r, pending = [] }) {
  const out = { requests: [] };
  const synced = (sync.state && sync.state.issues) || [];
  const busy = new Set(pending.map(q => q.session && q.session.issue));

  for (const t of cfg.targets) {
    if (pullsFailed.has(t.repo)) continue;
    const note = (pr, action, detail) => r.review.push({ target: t.repo, pr, action, detail });
    const seen = (state.rework && state.rework[t.repo]) || {};
    const record = (pr, head) => {
      if (!apply) return;
      state.rework = state.rework || {};
      state.rework[t.repo] = { ...(state.rework[t.repo] || {}), [pr]: head };
    };

    for (const si of synced) {
      if (!si.pr || si.repo !== t.repo) continue;
      const p = pulls.find(x => x.repo === t.repo && x.number === si.pr.number);
      if (!isOpen(p)) continue;
      // The comments were read by the sync at the head it saw; a head that has
      // moved since is judged next cycle.
      if (p.headRefOid !== si.pr.headSha) continue;
      const m = currentRework({ headSha: p.headRefOid, comments: si.pr.comments });
      if (!m || seen[p.number] === m.sha) continue;

      const id = scope.packageId(si.title) || `#${si.number}`;
      const reason = `review-failed: REWORK by ${m.who} at ${short(m.sha)}; address the review comments on PR #${p.number}`;
      const s = state.sessions[si.number];
      if (!s) {
        alarm('review-redispatch-failed', `${id}: REWORK on ${t.repo}#${p.number} at ${short(m.sha)}, but there is no session record on this machine, so nobody is re-dispatched`, si.number);
        record(p.number, m.sha);
        continue;
      }
      // A worker still running, parked, or waiting on a retry is not sent back
      // now; the marker is read again next cycle.
      if (s.status !== 'closed' || busy.has(s.issue)) {
        note(p.number, 'rework-held', `${id}: session is ${busy.has(s.issue) ? 're-dispatched already this cycle' : s.status}; REWORK by ${m.who} is read again next cycle`);
        continue;
      }
      if (!apply) { note(p.number, 'would-rework', `${id}: REWORK by ${m.who} at ${short(m.sha)}`); continue; }
      record(p.number, m.sha);
      note(p.number, 'rework', `${id}: REWORK by ${m.who} at ${short(m.sha)}`);
      out.requests.push({ session: s, next: 'review-failed', reason });
    }
  }
  return out;
}

module.exports = { stage, currentRework, REWORK };
