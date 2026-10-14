#!/usr/bin/env node
'use strict';
// V2 gate (#88, replaces #39): the eval suite fails when the worker contract
// loses its test-first rule, passes against the real file, and a per-suite cap
// below one eval's cost stops the suite. Settings live in v2-degraded-contract.json.
//
//   node evals/gates/v2-degraded-contract.js [--plan] [--record <file>] [--claude <bin>]
//
// --plan    builds the contract copy and case sets and checks the preconditions without calling claude.
// --record  writes every run (command, exit, per-eval status, reasons, cost) and every assertion as JSON.
// --claude  is passed through to evals/run.js.
//
// contract-failing-test-first carries only the task; the contract reaches claude
// through evals/run.js --contract. It runs N times against a temp copy with the
// test-first bullet removed, then N times against the repository file. The run
// counts are fixed in the JSON before any run, every run is recorded, and no run
// is repeated.
//
// contract-lane-blocker still quotes its rules in its prompt, so its quotes are
// rebound to each side's contract: a quoted sentence that is in the repository
// file but not in the side's copy is dropped. Against the real file the rebound
// case equals the committed one byte for byte. It runs once per side.
//
// evals/run.js runs unmodified, and the repository contract file is only read.
//
// Exit 0: every assertion held. Exit 1: an assertion failed. Exit 2: bad setup.

const fs = require('fs');
const os = require('os');
const path = require('path');
const crypto = require('crypto');
const { spawnSync } = require('child_process');

const REPO = path.resolve(__dirname, '../..');
const GATE_FILE = path.join(__dirname, 'v2-degraded-contract.json');
const rel = p => (path.isAbsolute(p) && p.startsWith(REPO + path.sep) ? path.relative(REPO, p) : p);
const usd = n => (n === null ? 'unknown' : `$${n.toFixed(4)}`);
const round = n => Math.round(n * 1e6) / 1e6;
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

// One side of the repeated case: how many of its runs failed, and whether the side
// meets its rule. A run that did not produce a pass or a fail (no results, not-run)
// is counted on its own and fails the side: it is neither evidence for nor against.
function tally(runs, k, side) {
  const statuses = runs.map(r => r.status);
  const failed = statuses.filter(s => s === 'failed').length;
  const passed = statuses.filter(s => s === 'passed').length;
  const other = statuses.length - failed - passed;
  const ok = other === 0 && (side === 'degraded' ? failed >= k : failed <= k);
  return { runs: statuses.length, failed, passed, other, ok };
}

function parseArgs(argv) {
  const o = { plan: false, record: null, claude: null };
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === '--plan') o.plan = true;
    else if (argv[i] === '--record' && argv[i + 1] !== undefined) o.record = argv[++i];
    else if (argv[i] === '--claude' && argv[i + 1] !== undefined) o.claude = argv[++i];
    else throw new Error(`unknown or incomplete argument: ${argv[i]}`);
  }
  return o;
}

function git(args) {
  const r = spawnSync('git', args, { cwd: REPO, maxBuffer: 16 * 1024 * 1024 });
  if (r.status !== 0) throw new Error(`git ${args.join(' ')}: ${String(r.stderr).trim()}`);
  return r.stdout;
}

function main() {
  let opts, gate;
  try {
    opts = parseArgs(process.argv.slice(2));
    gate = JSON.parse(fs.readFileSync(GATE_FILE, 'utf8'));
  } catch (e) {
    console.error(`gate: ${e.message}`);
    return 2;
  }

  const record = { gate: gate.id, package: gate.package, startedAt: new Date().toISOString(), head: null, branchCut: null, runs: [], assertions: [] };
  const failures = [];
  const assert = (ok, what) => {
    console.log(`${ok ? 'OK  ' : 'FAIL'} ${what}`);
    record.assertions.push({ ok, what });
    if (!ok) failures.push(what);
  };

  const contractPath = path.join(REPO, gate.contract);
  let realBuf, baseBuf;
  try {
    record.head = git(['rev-parse', 'HEAD']).toString().trim();
    record.branchCut = git(['merge-base', 'HEAD', gate.baseRef]).toString().trim();
    baseBuf = git(['show', `${record.branchCut}:${gate.contract}`]);
    realBuf = fs.readFileSync(contractPath);
  } catch (e) {
    console.error(`gate: ${e.message}`);
    return 2;
  }
  const realText = realBuf.toString('utf8');
  const hashBase = sha(baseBuf);
  console.log(`head ${record.head}`);
  console.log(`branch cut ${record.branchCut} (merge-base of HEAD and ${gate.baseRef})`);
  console.log(`contract ${gate.contract}`);
  console.log(`  sha256 at branch cut: ${hashBase}`);
  console.log(`  sha256 before runs:   ${sha(realBuf)}`);
  record.contract = { path: gate.contract, sha256AtBranchCut: hashBase, sha256Before: sha(realBuf), sha256After: null };
  assert(sha(realBuf) === hashBase, 'contract is byte-identical to its state at the branch cut, before the runs');

  const readCase = f => { const raw = fs.readFileSync(path.join(REPO, f)); return { file: f, raw, json: JSON.parse(raw.toString('utf8')) }; };
  const repeated = readCase(gate.repeated.case);
  const once = readCase(gate.once.case);
  const lowCases = gate.lowCap.cases.map(readCase);
  const budgetFile = path.join(REPO, gate.budget);
  const budget = JSON.parse(fs.readFileSync(budgetFile, 'utf8'));
  const N = gate.repeated.runsPerSide;
  const k = gate.repeated.k;

  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'v2r-gate-'));
  try {
    // The degraded copy lives only in the temp directory.
    const degradedText = degrade(realText, gate.degrade.removeBulletStartingWith);
    const degradedFile = path.join(tmp, 'worker-contract.degraded.md');
    fs.writeFileSync(degradedFile, degradedText);
    console.log(`degraded copy ${degradedFile}: ${realBuf.length - Buffer.byteLength(degradedText)} bytes removed (${gate.degrade.rule} rule)`);
    assert(!norm(degradedText).includes('Write the failing test before the change'), 'degraded copy no longer holds the test-first rule');
    assert(norm(realText).includes('Write the failing test before the change'), 'repository contract holds the test-first rule');
    assert(!/"/.test(repeated.json.prompt), `${repeated.json.id} prompt quotes nothing: the rule reaches it only through --contract`);

    const writeCase = (dir, c, text) => {
      fs.mkdirSync(dir, { recursive: true });
      // Unchanged cases are copied as raw bytes so the set is the committed set.
      fs.writeFileSync(path.join(dir, path.basename(c.file)), text === null ? c.raw : text);
      return dir;
    };
    const boundOnce = copyText => {
      const prompt = bindToContract(once.json.prompt, realText, copyText);
      return prompt === once.json.prompt ? null : JSON.stringify({ ...once.json, prompt }, null, 2) + '\n';
    };
    const repeatedDir = writeCase(path.join(tmp, 'cases-repeated'), repeated, null);
    const onceDegradedText = boundOnce(degradedText);
    const onceDegradedDir = writeCase(path.join(tmp, 'cases-once-degraded'), once, onceDegradedText);
    const onceRealText = boundOnce(realText);
    const onceRealDir = writeCase(path.join(tmp, 'cases-once-real'), once, onceRealText);
    console.log(`${once.json.id} against the degraded copy: ${onceDegradedText === null ? 'prompt unchanged by rebinding' : 'prompt rebound'}`);
    assert(onceRealText === null, `${once.json.id} against the repository file is byte-identical to the committed case`);
    const lowDir = path.join(tmp, 'cases-low-cap');
    for (const c of lowCases) writeCase(lowDir, c, null);
    const lowBudgetFile = path.join(tmp, 'budget-low-cap.json');
    fs.writeFileSync(lowBudgetFile, JSON.stringify({ ...budget, perSuiteUsd: gate.lowCap.perSuiteUsd }, null, 2) + '\n');

    if (opts.plan) {
      console.log(`\n--plan: no evals run. Would run ${N} + ${N} ${repeated.json.id}, 1 + 1 ${once.json.id}, 1 low-cap suite.`);
      return failures.length ? 1 : 0;
    }

    let seq = 0;
    const runSuite = (label, side, casesDir, contractFile, budgetPath) => {
      seq += 1;
      const resultsFile = path.join(tmp, `run-${seq}.json`);
      const args = [path.join(REPO, 'evals/run.js'), '--cases', casesDir, '--budget', budgetPath, '--results', resultsFile, '--contract', contractFile];
      if (opts.claude) args.push('--claude', opts.claude);
      const command = `node ${args.map(rel).join(' ')}`;
      console.log(`\n== run ${seq}: ${label}`);
      console.log(`$ ${command}`);
      const r = spawnSync(process.execPath, args, { cwd: REPO, encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 });
      process.stdout.write(r.stdout || '');
      if (r.stderr) process.stdout.write(r.stderr);
      console.log(`exit ${r.status}`);
      const results = fs.existsSync(resultsFile) ? JSON.parse(fs.readFileSync(resultsFile, 'utf8')) : null;
      const evals = results ? results.evals : [];
      const run = {
        seq, label, side, command, exit: r.status, stdout: r.stdout || '',
        evals: evals.map(e => ({ id: e.id, status: e.status, costUsd: e.costUsd, reasons: e.reasons })),
        measuredUsd: results ? results.suite.measuredUsd : null,
        // The repeated and once runs hold one case each; a missing result is not a pass.
        status: evals.length === 1 ? evals[0].status : (results ? 'mixed' : 'no-results'),
      };
      record.runs.push(run);
      return run;
    };

    const degradedRuns = [];
    for (let i = 1; i <= N; i++) degradedRuns.push(runSuite(`degraded ${i}/${N}: ${repeated.json.id} --contract degraded copy`, 'degraded', repeatedDir, degradedFile, budgetFile));
    const onceDegraded = runSuite(`degraded: ${once.json.id} --contract degraded copy`, 'degraded', onceDegradedDir, degradedFile, budgetFile);
    const realRuns = [];
    for (let i = 1; i <= N; i++) realRuns.push(runSuite(`real ${i}/${N}: ${repeated.json.id} --contract repository file`, 'real', repeatedDir, contractPath, budgetFile));
    const onceReal = runSuite(`real: ${once.json.id} --contract repository file`, 'real', onceRealDir, contractPath, budgetFile);

    const cheapest = (() => {
      const costs = record.runs.flatMap(r => r.evals.map(e => e.costUsd));
      return costs.length && costs.every(c => c !== null) ? Math.min(...costs) : null;
    })();
    const low = runSuite(`low cap: per-suite cap ${usd(gate.lowCap.perSuiteUsd)}, --contract repository file`, 'low-cap', lowDir, contractPath, lowBudgetFile);

    console.log('\n== results');
    const td = tally(degradedRuns, k, 'degraded');
    const tr = tally(realRuns, k, 'real');
    record.tally = { degraded: td, real: tr };
    console.log(`degraded ${repeated.json.id}: ${degradedRuns.map(r => r.status).join(', ')}`);
    console.log(`real     ${repeated.json.id}: ${realRuns.map(r => r.status).join(', ')}`);
    assert(td.ok, `degraded copy: ${td.failed} of ${td.runs} ${repeated.json.id} runs failed${td.other ? `, ${td.other} produced no pass or fail` : ''} (want at least ${k} of ${N})`);
    assert(tr.ok, `repository file: ${tr.failed} of ${tr.runs} ${repeated.json.id} runs failed${tr.other ? `, ${tr.other} produced no pass or fail` : ''} (want at most ${k} of ${N})`);
    assert(onceDegraded.status === 'passed', `degraded copy: ${once.json.id} ${onceDegraded.status} (want passed)`);
    assert(onceReal.status === 'passed', `repository file: ${once.json.id} ${onceReal.status} (want passed)`);

    assert(cheapest !== null && gate.lowCap.perSuiteUsd < cheapest,
      `low cap ${usd(gate.lowCap.perSuiteUsd)} is below the cheapest eval measured in this gate (${usd(cheapest)})`);
    const report = /SUITE CAP REACHED: spent \$\d+\.\d{4}, cap \$\d+\.\d{4}/.exec(low.stdout);
    const lowPassed = low.evals.filter(e => e.status === 'passed').length;
    assert(low.exit === 1, `low cap: exit ${low.exit} (want 1)`);
    assert(!!report, `low cap: prints spent and cap${report ? ` ("${report[0]}")` : ''}`);
    assert(lowPassed === 0 && !/^PASS /m.test(low.stdout), `low cap: ${lowPassed} passed, ${/^PASS /m.test(low.stdout) ? 'a' : 'no'} PASS line (want 0, none)`);

    const costs = record.runs.map(r => r.measuredUsd);
    const total = costs.every(c => c !== null) ? round(costs.reduce((a, b) => a + b, 0)) : null;
    record.measuredUsd = total;
    console.log(`\ngate cost by run: ${record.runs.map(r => `${r.seq}=${usd(r.measuredUsd)}`).join(' ')}`);
    assert(total !== null && total < budget.perSuiteUsd, `gate measured cost ${total === null ? 'unknown' : `${usd(total)} [measured]`} is under the per-suite cap ${usd(budget.perSuiteUsd)}`);
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true });
    const hashAfter = sha(fs.readFileSync(contractPath));
    record.contract.sha256After = hashAfter;
    console.log(`  sha256 after runs:    ${hashAfter}`);
    assert(hashAfter === hashBase, 'contract is byte-identical to its state at the branch cut, after the runs');
    record.finishedAt = new Date().toISOString();
    record.result = failures.length ? 'GATE FAIL' : 'GATE PASS';
    if (opts.record && !opts.plan) {
      for (const r of record.runs) delete r.stdout;
      fs.mkdirSync(path.dirname(path.resolve(opts.record)), { recursive: true });
      fs.writeFileSync(opts.record, JSON.stringify(record, null, 2) + '\n');
      console.log(`record written to ${rel(path.resolve(opts.record))}`);
    }
  }

  console.log(failures.length ? `\nGATE FAIL: ${failures.length} assertion(s) failed` : '\nGATE PASS');
  return failures.length ? 1 : 0;
}

module.exports = { degrade, bindToContract, tally };
if (require.main === module) process.exitCode = main();
