#!/usr/bin/env node
'use strict';
// check-stamp.js <pr.json> — a PR titled "[READY]: ..." must carry a VERIFIED
// stamp comment whose sha equals the PR head sha.
// pr.json: { "title": string, "headSha": string, "comments": [string] }
// Exit 0: pass, or not a READY PR. Exit 1: READY PR without a current stamp,
// or input that cannot be read.
const fs = require('fs');
const path = require('path');
const { currentStamp } = require(path.join(
  __dirname, '..', 'plugins', 'agentic-work-packages', 'skills', 'agentic-work-packages', 'assets', 'scripts', 'stamp.js'));

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

const stamp = currentStamp(pr);
if (!stamp) {
  console.error(`check-stamp: no comment carries "VERIFIED: <suite> @ ${pr.headSha}".`);
  console.error('A push after a stamp voids it. Re-run the suite and post a new stamp.');
  process.exit(1);
}
console.log(`check-stamp: VERIFIED ${stamp.suite} @ ${stamp.sha}`);
