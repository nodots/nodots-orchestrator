'use strict';

/*
 * The merge stage: for each target with `autoMerge` (config.js), merge every
 * open package PR whose base is the target's integrationBranch and that meets
 * the merge condition. It runs after verify and review and before launch.
 *
 * For each open PR of the epic's packages on the target, read fresh:
 *   1. a protected base (config.js isProtected) is refused, merge-protected-refused,
 *      before anything else is checked or asked;
 *   2. a base other than the integration branch is skipped;
 *   3. the condition, in order, the first unmet one named in the report:
 *        a current VERIFIED stamp at the head (stamp.js currentStamp);
 *        reviewMet(policy, currentReviews) when stamp.js exports reviewMet,
 *          else skipped and said so;
 *        gh pr checks all green (pass or skipping; none reported is not green);
 *        mergeable is MERGEABLE;
 *   4. `gh pr merge --merge --match-head-commit <head>`, so a push after the
 *      checks fails the merge instead of landing unchecked. A failure is
 *      merge-failed with gh's message, and is not retried this cycle.
 *
 * Fleet cannot see the GitHub branch-protection rules on the integration
 * branch; one that blocks the merge surfaces as merge-failed.
 *
 * Dry run: every read is made, no merge. The report says which PRs would merge
 * and why the others would not.
 */

const path = require('path');
const scope = require('./scope');
const { isProtected } = require('./config');

const short = sha => (typeof sha === 'string' ? sha.slice(0, 7) : String(sha));
const oneLine = s => String(s === undefined || s === null ? '' : s).replace(/\s+/g, ' ').trim().slice(0, 300);
const isOpen = p => Boolean(p) && String(p.state).toUpperCase() === 'OPEN';
const GREEN = new Set(['pass', 'skipping']);

// The first unmet condition at <head>, or null when every one holds.
function unmet({ stamp, policy, comments, head, checks, mergeable }) {
  if (!stamp.currentStamp({ headSha: head, comments })) return `no current VERIFIED stamp at ${short(head)}`;
  if (typeof stamp.reviewMet === 'function') {
    const reviews = stamp.currentReviews({ headSha: head, comments });
    if (!stamp.reviewMet(policy, reviews)) return `review policy not met: ${reviews.length} of ${policy.passes} REVIEWED stamp(s) at ${short(head)}`;
  }
  const c = checks();
  if (!c.ok) return `gh pr checks: ${oneLine(c.error)}`;
  if (!c.checks.length) return 'gh pr checks: no checks reported';
  const red = c.checks.filter(x => !GREEN.has(x.bucket));
  if (red.length) return `gh pr checks not all green: ${red.map(x => `${oneLine(x.name)} ${oneLine(x.bucket)}`).join(', ')}`;
  if (mergeable !== 'MERGEABLE') return `mergeable is ${mergeable}, not MERGEABLE`;
  return null;
}

// stage(ctx) -> undefined
// ctx: { cfg, apply, tracker, pulls, pullsFailed (Set of repos), sync, alarm, r }
// Mutates r (merge notes, movement). Keeps no local state.
function stage({ cfg, apply, tracker, pulls, pullsFailed = new Set(), sync, alarm, r }) {
  const targets = cfg.targets.filter(t => t.autoMerge);
  if (!targets.length) return;
  const stamp = require(path.join(cfg.scriptsDir, 'stamp.js'));
  const noReview = typeof stamp.reviewMet === 'function' ? '' : '; review not checked: stamp.js has no reviewMet';
  const synced = (sync.state && sync.state.issues) || [];
  const policies = (sync.state && sync.state.reviewPolicies) || {};

  for (const t of targets) {
    const note = (pr, action, detail) => r.merge.push({ target: t.repo, pr, action, detail });
    if (pullsFailed.has(t.repo)) { note('-', 'skipped', 'the PR list for this target failed (pulls-failed)'); continue; }
    const seen = new Set();
    for (const si of synced) {
      if (!si.pr || si.repo !== t.repo || seen.has(si.pr.number)) continue;
      const listed = pulls.find(p => p.repo === t.repo && p.number === si.pr.number);
      if (!isOpen(listed)) continue;
      seen.add(si.pr.number);
      const n = si.pr.number;
      const id = scope.packageId(si.title) || `#${si.number}`;

      const v = tracker.viewPull(t.repo, n);
      if (!v.ok) { alarm('merge-view-failed', `${t.repo}#${n}: ${oneLine(v.error)}; not merged`, si.number); note(n, 'failed', `view: ${oneLine(v.error)}`); continue; }
      const p = v.pull;
      if (!isOpen(p)) { note(n, 'skipped', `PR is ${p.state}, not open`); continue; }
      const base = p.baseRefName;
      // First, before any other check: a protected base is never merged.
      if (isProtected(cfg, t, base)) {
        alarm('merge-protected-refused', `${t.repo}#${n} (${id}) has base ${base}, a protected branch; fleet merges only into ${t.integrationBranch}`, si.number);
        note(n, 'refused', `base ${base} is protected`);
        continue;
      }
      if (base !== t.integrationBranch) { note(n, 'skipped', `base ${base} is not the integration branch ${t.integrationBranch}`); continue; }

      const head = p.headRefOid;
      const why = unmet({ stamp, policy: policies[t.repo] || null, comments: si.pr.comments || [], head, checks: () => tracker.prChecks(t.repo, n), mergeable: p.mergeable });
      if (why) { note(n, 'held', `${why}${noReview}`); continue; }
      if (!apply) { note(n, 'would-merge', `${id} at ${short(head)} into ${base}${noReview}`); continue; }

      const m = tracker.mergePr(t.repo, n, head);
      if (!m.ok) {
        alarm('merge-failed', `${t.repo}#${n} (${id}) at ${short(head)}: ${oneLine(m.error)}; not retried this cycle`, si.number);
        note(n, 'failed', oneLine(m.error));
        continue;
      }
      const after = tracker.viewPull(t.repo, n);
      const sha = after.ok && after.pull.mergeCommit && after.pull.mergeCommit.oid;
      if (!sha) alarm('merge-sha-unread', `${t.repo}#${n} (${id}) merged, but its merge commit could not be read: ${after.ok ? 'no mergeCommit' : oneLine(after.error)}`, si.number);
      r.movement.push({ package: id, issue: si.number, artifact: { type: 'merged', ref: sha || '(merge commit unread)', detail: `${t.repo}#${n} into ${base} at ${short(head)}` } });
      note(n, 'merged', `${id} at ${short(head)} into ${base} as ${sha ? short(sha) : '(merge commit unread)'}${noReview}`);
    }
  }
}

module.exports = { stage, unmet };
