'use strict';
// The one definition of the VERIFIED and REVIEWED stamps and of what makes each
// current. Callers: sync-cells.sh (label derivation) and scripts/check-stamp.js
// (PR check).

const STAMP = /^VERIFIED:\s*(\S.*?)\s+@\s+([0-9a-f]{40})\s*$/m;
const REVIEW_STAMP = /^REVIEWED:\s*(\S.*?)\s+@\s+([0-9a-f]{40})\s*$/m;

// A stamp is current only when it names the PR's head sha. Any push after the
// stamp changes that sha and voids the evidence.
function currentStamp(pr) {
  if (!pr || !pr.headSha) return null;
  for (const body of pr.comments || []) {
    const m = STAMP.exec(String(body));
    if (m && m[2] === pr.headSha) return { suite: m[1], sha: m[2] };
  }
  return null;
}

// Every REVIEWED stamp at the head, in comment order, one per reviewer name: a
// reviewer that stamps twice is still one review.
function currentReviews(pr) {
  if (!pr || !pr.headSha) return [];
  const all = new RegExp(REVIEW_STAMP.source, 'gm');
  const seen = new Set();
  const reviews = [];
  for (const body of pr.comments || []) {
    for (const m of String(body).matchAll(all)) {
      if (m[2] !== pr.headSha || seen.has(m[1])) continue;
      seen.add(m[1]);
      reviews.push({ reviewer: m[1], sha: m[2] });
    }
  }
  return reviews;
}

// A null policy is met: a repo that declares no review policy needs none.
// `reviews` is currentReviews' output, already one per reviewer.
function reviewMet(policy, reviews) {
  if (!policy) return true;
  return reviews.length >= policy.passes;
}

module.exports = { STAMP, REVIEW_STAMP, currentStamp, currentReviews, reviewMet };
