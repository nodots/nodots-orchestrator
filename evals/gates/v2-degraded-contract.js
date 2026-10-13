#!/usr/bin/env node
'use strict';
// V2 gate (#39): the worker-contract evals fail when the contract loses its
// test-first rule, pass against the real file, and a per-suite cap below one
// eval's cost stops the suite. Settings live in v2-degraded-contract.json.
//
//   node evals/gates/v2-degraded-contract.js [--plan]
//
// --plan builds the case sets and checks the preconditions without calling claude.
//
// The contract cases quote the contract in their prompts rather than reading the
// file. Each run rebinds those quotes to a copy of the contract: a quoted sentence
// that is in the repository file but not in the copy is dropped. Against the real
// file the rebound cases equal the committed ones byte for byte. evals/run.js runs
// unmodified, and the repository contract file is only ever read.
//
// Exit 0: every assertion held. Exit 1: an assertion failed. Exit 2: bad setup.

const fs = require('fs');
const os = require('os');
const path = require('path');
const crypto = require('crypto');
const { spawnSync } = require('child_process');

const REPO = path.resolve(__dirname, '../..');
const GATE = JSON.parse(fs.readFileSync(path.join(__dirname, 'v2-degraded-contract.json'), 'utf8'));
const rel = p => (path.isAbsolute(p) && p.startsWith(REPO + path.sep) ? path.relative(REPO, p) : p);
const usd = n => `$${n.toFixed(4)}`;
const sha = buf => crypto.createHash('sha256').update(buf).digest('hex');
// Markdown emphasis and line wrapping differ between the file and the prompt quotes.
const norm = s => s.replace(/[*`]/g, '').replace(/\s+/g, ' ').trim();

// Remove one bullet: its first line and the indented lines that continue it.
function degrade(text, marker) {
  const lines = text.split('\n');
  const start = lines.findIndex(l => l.startsWith(marker));
  if (start < 0) throw new Error(`no line in the contract starts with ${marker}`);
  let end = start + 1;
  while (end < lines.length && lines[end].startsWith('  ')) end++;
  return lines.slice(0, start).concat(lines.slice(end)).join('\n');
}

// Drop from each "quoted" span the sentences the real contract has and the copy lacks.
function bindToContract(prompt, realText, copyText) {
  const real = norm(realText);
  const copy = norm(copyText);
  return prompt.replace(/"([^"]*)"/g, (whole, span) => {
    const sentences = span.split(/(?<=\.)\s+/);
    const kept = sentences.filter(s => !(real.includes(norm(s)) && !copy.includes(norm(s))));
    if (kept.length === sentences.length) return whole;
    return kept.length ? `"${kept.join(' ')}"` : '';
  });
}

function writeCases(dir, cases, realText, copyText) {
  fs.mkdirSync(dir, { recursive: true });
  return cases.map(({ file, raw, json }) => {
    const bound = { ...json, prompt: bindToContract(json.prompt, realText, copyText) };
    // Unchanged cases are copied as raw bytes so the real set is the committed set.
    const out = bound.prompt === json.prompt ? raw : JSON.stringify(bound, null, 2) + '\n';
    fs.writeFileSync(path.join(dir, path.basename(file)), out);
    return { id: json.id, changed: bound.prompt !== json.prompt, prompt: bound.prompt };
  });
}

function runSuite(label, casesDir, budgetFile, resultsFile) {
  const args = [path.join(REPO, 'evals/run.js'), '--cases', casesDir, '--budget', budgetFile, '--results', resultsFile];
  console.log(`\n== run ${label}`);
  console.log(`$ node ${args.map(rel).join(' ')}`);
  const r = spawnSync(process.execPath, args, { cwd: REPO, encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 });
  process.stdout.write(r.stdout || '');
  if (r.stderr) process.stdout.write(r.stderr);
  console.log(`exit ${r.status}`);
  const results = fs.existsSync(resultsFile) ? JSON.parse(fs.readFileSync(resultsFile, 'utf8')) : null;
  return { exit: r.status, stdout: r.stdout || '', results };
}

const counts = res => {
  const evals = res ? res.evals : [];
  const n = s => evals.filter(e => e.status === s).length;
  return { total: evals.length, passed: n('passed'), failed: n('failed'), notRun: n('not-run') };
};

function main() {
  const plan = process.argv.slice(2).includes('--plan');
  const failures = [];
  const assert = (ok, what) => { console.log(`${ok ? 'OK  ' : 'FAIL'} ${what}`); if (!ok) failures.push(what); };

  const contractPath = path.join(REPO, GATE.contract);
  const realBuf = fs.readFileSync(contractPath);
  const realText = realBuf.toString('utf8');
  const hashBefore = sha(realBuf);
  const base = spawnSync('git', ['show', `${GATE.baseRef}:${GATE.contract}`], { cwd: REPO, maxBuffer: 16 * 1024 * 1024 });
  if (base.status !== 0) { console.error(`gate: cannot read ${GATE.contract} at ${GATE.baseRef}: ${String(base.stderr).trim()}`); return 2; }
  const hashBase = sha(base.stdout);
  console.log(`contract ${GATE.contract}`);
  console.log(`  sha256 at ${GATE.baseRef}: ${hashBase}`);
  console.log(`  sha256 now:            ${hashBefore}`);
  assert(hashBefore === hashBase, `contract is byte-identical to ${GATE.baseRef} before the runs`);

  const degradedText = degrade(realText, GATE.degrade.removeBulletStartingWith);
  const cases = GATE.cases.map(f => {
    const raw = fs.readFileSync(path.join(REPO, f));
    return { file: f, raw, json: JSON.parse(raw.toString('utf8')) };
  });
  const budgetFile = path.join(REPO, GATE.budget);
  const budget = JSON.parse(fs.readFileSync(budgetFile, 'utf8'));

  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'v2-gate-'));
  try {
    // The degraded copy lives only in the temp directory.
    const degradedFile = path.join(tmp, 'worker-contract.degraded.md');
    fs.writeFileSync(degradedFile, degradedText);
    console.log(`degraded copy ${degradedFile}: ${realText.length - degradedText.length} bytes removed (${GATE.degrade.rule} rule)`);
    assert(!norm(degradedText).includes('Write the failing test before the change'), 'degraded copy no longer holds the test-first rule');

    const degradedSet = writeCases(path.join(tmp, 'cases-degraded'), cases, realText, degradedText);
    const realSet = writeCases(path.join(tmp, 'cases-real'), cases, realText, realText);
    for (const c of degradedSet) {
      console.log(`degraded case ${c.id}: ${c.changed ? 'prompt rebound' : 'prompt unchanged'}`);
      if (c.changed) console.log(`  prompt now begins: ${JSON.stringify(c.prompt.slice(0, 120))}`);
    }
    assert(degradedSet.some(c => c.changed), 'at least one degraded case prompt lost the removed rule');
    assert(realSet.every((c, i) => fs.readFileSync(path.join(tmp, 'cases-real', path.basename(cases[i].file))).equals(cases[i].raw)),
      'real-file cases are byte-identical to the committed cases');

    if (plan) {
      console.log('\n--plan: no evals run');
      return failures.length ? 1 : 0;
    }

    const degraded = runSuite('degraded: worker-contract evals against the degraded copy', path.join(tmp, 'cases-degraded'), budgetFile, path.join(tmp, 'degraded.json'));
    const dc = counts(degraded.results);
    assert(degraded.exit === 1 && dc.failed >= 1, `degraded copy: exit ${degraded.exit}, ${dc.failed} of ${dc.total} failed (want exit 1, at least one failed)`);

    const real = runSuite('real: worker-contract evals against the repository file', path.join(tmp, 'cases-real'), budgetFile, path.join(tmp, 'real.json'));
    const rc = counts(real.results);
    assert(real.exit === 0 && rc.total === cases.length && rc.passed === rc.total, `real file: exit ${real.exit}, ${rc.passed} of ${rc.total} passed (want exit 0, all passed)`);

    const realCosts = real.results ? real.results.evals.map(e => e.costUsd) : [];
    const cheapest = realCosts.length && realCosts.every(c => c !== null) ? Math.min(...realCosts) : null;
    assert(cheapest !== null && GATE.lowCapUsd < cheapest,
      `low cap ${usd(GATE.lowCapUsd)} is below the cheapest measured eval in the real run (${cheapest === null ? 'unknown' : usd(cheapest)})`);
    const lowBudgetFile = path.join(tmp, 'budget-low-cap.json');
    fs.writeFileSync(lowBudgetFile, JSON.stringify({ ...budget, perSuiteUsd: GATE.lowCapUsd }, null, 2) + '\n');
    const low = runSuite(`low cap: per-suite cap ${usd(GATE.lowCapUsd)}`, path.join(tmp, 'cases-real'), lowBudgetFile, path.join(tmp, 'low-cap.json'));
    const lc = counts(low.results);
    const report = /SUITE CAP REACHED: spent \$\d+\.\d{4}, cap \$\d+\.\d{4}/.exec(low.stdout);
    assert(low.exit === 1, `low cap: exit ${low.exit} (want 1)`);
    assert(!!report, `low cap: prints spent and cap${report ? ` ("${report[0]}")` : ''}`);
    assert(lc.passed === 0 && !/^PASS /m.test(low.stdout), `low cap: ${lc.passed} passed, no PASS line (want 0)`);

    const runCosts = [degraded, real, low].map(r => (r.results ? r.results.suite.measuredUsd : null));
    const total = runCosts.every(c => c !== null) ? Math.round(runCosts.reduce((a, b) => a + b, 0) * 1e6) / 1e6 : null;
    console.log(`\ngate cost: degraded ${runCosts[0] === null ? 'unknown' : usd(runCosts[0])}, real ${runCosts[1] === null ? 'unknown' : usd(runCosts[1])}, low cap ${runCosts[2] === null ? 'unknown' : usd(runCosts[2])}`);
    assert(total !== null && total < budget.perSuiteUsd, `gate measured cost ${total === null ? 'unknown' : `${usd(total)} [measured]`} is under the per-suite cap ${usd(budget.perSuiteUsd)}`);
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true });
    const hashAfter = sha(fs.readFileSync(contractPath));
    console.log(`  sha256 after runs:     ${hashAfter}`);
    assert(hashAfter === hashBase, `contract is byte-identical to ${GATE.baseRef} after the runs`);
  }

  console.log(failures.length ? `\nGATE FAIL: ${failures.length} assertion(s) failed` : '\nGATE PASS');
  return failures.length ? 1 : 0;
}

process.exitCode = main();
