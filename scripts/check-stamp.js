#!/usr/bin/env node
'use strict';
// check-stamp.js <pr.json> — a PR titled "[READY]: ..." must carry a VERIFIED
// stamp comment whose sha equals the PR head sha. When the base branch's
// manifest has a `review` policy, the head's REVIEWED stamps must meet it too.
// pr.json: { "title": string, "headSha": string, "comments": [string],
//            "manifest": string | null }
// `manifest` is the raw text of .claude/standards.json on the PR's base branch,
// null or absent when the base has none. The check reads nothing else.
// Exit 0: pass, or not a READY PR. Exit 1: READY PR without a current stamp,
// short of the review policy, or input that cannot be read.
const fs = require('fs');
const path = require('path');
const ASSETS = path.join(
  __dirname, '..', 'plugins', 'agentic-work-packages', 'skills', 'agentic-work-packages', 'assets', 'scripts');
const { currentStamp, currentReviews, reviewMet } = require(path.join(ASSETS, 'stamp.js'));
const { validateReview } = require(path.join(ASSETS, 'check-standards.js'));

const count = (n, one, many) => `${n} ${n === 1 ? one : many}`;

const file = process.argv[2];
let pr;
try {
  pr = JSON.parse(fs.readFileSync(file, 'utf8'));
} catch (err) {
  console.error(`check-stamp: cannot read ${file}: ${err.message}`);
  process.exit(1);
}

if (!/^\[READY\]:/.test(String(pr.title || ''))) {
  console.log('check-stamp: title does not start with [READY]:, nothing to check.');
  process.exit(0);
}
if (!pr.headSha) {
  console.error('check-stamp: READY PR has no head sha in the input; cannot judge the stamp.');
  process.exit(1);
}

// The review policy from the base branch's manifest. A manifest that cannot be
// read or judged fails the check: passing it would skip the policy it may hold.
let policy = null;
if (pr.manifest !== null && pr.manifest !== undefined) {
  const at = 'check-stamp: base branch .claude/standards.json';
  let m;
  try {
    m = JSON.parse(String(pr.manifest));
  } catch (err) {
    console.error(`${at}: not valid JSON: ${err.message}`);
    process.exit(1);
  }
  if (m === null || typeof m !== 'object' || Array.isArray(m)) {
    console.error(`${at}: manifest: must be a JSON object`);
    process.exit(1);
  }
  const review = Object.prototype.hasOwnProperty.call(m, 'review') ? m.review : null;
  const defects = validateReview(review);
  if (defects.length) {
    for (const d of defects) console.error(`${at}: ${d}`);
    process.exit(1);
  }
  policy = review;
}

const failures = [];
const stamp = currentStamp(pr);
if (!stamp) {
  failures.push(`check-stamp: no comment carries "VERIFIED: <suite> @ ${pr.headSha}".`,
    'A push after a stamp voids it. Re-run the suite and post a new stamp.');
}

let reviewLine = '';
if (policy) {
  const reviews = currentReviews(pr);
  const found = reviews.length ? reviews.map(r => r.reviewer).join(', ') : 'none';
  const short = policy.passes - reviews.length;
  reviewLine = `REVIEWED ${found} @ ${pr.headSha}; the review policy needs ${count(policy.passes, 'review', 'reviews')}`;
  if (!reviewMet(policy, reviews)) {
    failures.push(`check-stamp: ${reviewLine}, missing ${count(short, 'review', 'reviews')}.`,
      'Only REVIEWED stamps at the head count, one per reviewer.');
  }
}

if (failures.length) {
  for (const f of failures) console.error(f);
  process.exit(1);
}
console.log(`check-stamp: VERIFIED ${stamp.suite} @ ${stamp.sha}`);
if (reviewLine) console.log(`check-stamp: ${reviewLine}`);
