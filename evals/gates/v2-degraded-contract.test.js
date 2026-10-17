#!/usr/bin/env node
'use strict';
// Fixture test for the V2 gate helpers: the degraded copy, the quote rebinding,
// and the k-of-N rule for each side. No model is called.
//
//   node evals/gates/v2-degraded-contract.test.js
//
// Exit 0 when every check holds, 1 otherwise. Prints "--- N checks, M failed".

const fs = require('fs');
const path = require('path');
const { degrade, bindToContract, tally } = require('./v2-degraded-contract');

const ROOT = path.resolve(__dirname, '../..');
const GATE = JSON.parse(fs.readFileSync(path.join(__dirname, 'v2-degraded-contract.json'), 'utf8'));

let run = 0, failed = 0;
function check(ok, label, detail) {
  run++;
  if (ok) { console.log(`  ok    ${label}`); return; }
  failed++;
  console.log(`  FAIL  ${label}`);
  if (detail) console.log(`        ${detail}`);
}
const eq = (want, got, label) => check(JSON.stringify(want) === JSON.stringify(got), label, `expected ${JSON.stringify(want)}, got ${JSON.stringify(got)}`);

// 1. degrade removes the bullet and its continuation lines, and nothing else.
const text = '## 4\n\n- **Rule A.** first line\n  continues here\n  and here.\n- **Rule B.** stays\n';
eq('## 4\n\n- **Rule B.** stays\n', degrade(text, '- **Rule A.**'), 'degrade removes the bullet and its indented continuation');
let threw = false;
try { degrade(text, '- **Missing.**'); } catch (e) { threw = /no line in the contract starts with/.test(e.message); }
check(threw, 'degrade throws when the marker is absent, never returns the text unchanged');

// 2. degrade on the repository contract removes the test-first rule only.
const contract = fs.readFileSync(path.join(ROOT, GATE.contract), 'utf8');
const copy = degrade(contract, GATE.degrade.removeBulletStartingWith);
check(contract.includes('Write the failing test before the change.') && !copy.includes('Write the failing test before the change.'), 'the copy lacks the test-first rule the repository file has');
check(copy.includes('A bug fix ships a regression fixture'), 'the next bullet in section 4 is kept');
eq(contract.split('\n').length - 4, copy.split('\n').length, 'the copy is the repository file less the four lines of the bullet');

// 3. bindToContract drops quoted sentences the copy lacks, and leaves other quotes alone.
const real = 'One. Two is here. Three.';
const less = 'One. Three.';
eq('say "One. Three." and "Other."', bindToContract('say "One. Two is here. Three." and "Other."', real, less), 'a removed sentence is dropped from the quote');
eq('say  then', bindToContract('say "Two is here." then', real, less), 'a quote left empty is removed');
eq('say "One. Two is here."', bindToContract('say "One. Two is here."', real, real), 'against the real text nothing changes');

// 4. tally applies the k-of-N rule per side; a run with no pass or fail fails the side.
const runs = s => s.split('').map(c => ({ status: { p: 'passed', f: 'failed', n: 'not-run' }[c] }));
eq({ runs: 8, failed: 1, passed: 7, other: 0, ok: true }, tally(runs('fppppppp'), 1, 'degraded'), 'degraded: 1 of 8 failed meets k = 1');
eq(false, tally(runs('pppppppp'), 1, 'degraded').ok, 'degraded: 0 of 8 failed does not');
eq(true, tally(runs('pppppppf'), 1, 'real').ok, 'real: 1 of 8 failed is allowed');
eq(false, tally(runs('ppppppff'), 1, 'real').ok, 'real: 2 of 8 failed is not');
eq(false, tally(runs('ppppppnp'), 1, 'real').ok, 'real: a not-run run fails the side');
eq(false, tally(runs('fffffffn'), 1, 'degraded').ok, 'degraded: a not-run run fails the side');

// 5. The run counts are fixed in the gate file before any run.
eq([8, 1], [GATE.repeated.runsPerSide, GATE.repeated.k], 'N = 8 and k = 1 in the gate file');

console.log(`  --- ${run} checks, ${failed} failed`);
process.exitCode = failed ? 1 : 0;
