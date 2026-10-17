'use strict';
// The one definition of the VERIFIED stamp and of what makes it current.
// Callers: sync-cells.sh (label derivation) and scripts/check-stamp.js (PR check).

const STAMP = /^VERIFIED:\s*(\S.*?)\s+@\s+([0-9a-f]{40})\s*$/m;

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

module.exports = { STAMP, currentStamp };
