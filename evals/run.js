#!/usr/bin/env node
'use strict';
// Non-interactive eval runner. Runs every case in --cases through `claude -p`
// with --max-budget-usd, enforces evals/budget.json, and writes machine-readable results.
//
//   node evals/run.js [--cases evals/cases] [--budget evals/budget.json] [--results out.json]
//                     [--workdir <dir, default: fresh temp dir>] [--claude claude] [--month-spent USD]
//
// Exit 0: every eval ran and passed. Exit 1: any eval failed or did not run.
// Exit 2: bad input (missing budget, no cases, malformed case). An eval that did
// not run is never a pass.

const fs = require('fs');
const os = require('os');
const path = require('path');
const { loadBudget, Ledger, usd } = require('./lib/budget');
const { loadCases } = require('./lib/cases');
const { runClaude, runChecks } = require('./lib/exec');

const REPO = path.resolve(__dirname, '..');

function parseArgs(argv) {
  const o = { cases: path.join(REPO, 'evals/cases'), budget: path.join(REPO, 'evals/budget.json'), results: null,
    workdir: null, claude: process.env.CLAUDE_BIN || 'claude', monthSpent: null };
  const flags = { '--cases': 'cases', '--budget': 'budget', '--results': 'results', '--workdir': 'workdir', '--claude': 'claude', '--month-spent': 'monthSpent' };
  for (let i = 0; i < argv.length; i += 2) {
    const key = flags[argv[i]];
    if (!key || argv[i + 1] === undefined) throw new Error(`unknown or incomplete argument: ${argv[i]}`);
    o[key] = argv[i + 1];
  }
  if (o.monthSpent !== null) {
    const n = Number(o.monthSpent);
    if (!Number.isFinite(n) || n < 0) throw new Error(`--month-spent must be a number >= 0, got ${o.monthSpent}`);
    o.monthSpent = n;
  }
  return o;
}

const costText = c => (c === null ? 'cost unknown [unknown]' : `${usd(c)} [measured]`);

function runEval(c, { allowance, opts, budget }) {
  const timeoutSeconds = c.timeoutSeconds || budget.timeoutSeconds || 600;
  const r = runClaude({ bin: opts.claude, prompt: c.prompt, allowance, model: c.model || budget.model,
    permissionMode: c.permissionMode || 'acceptEdits', workdir: opts.workdir, timeoutSeconds });
  const reasons = [];
  if (r.spawnError) reasons.push(`could not start claude: ${r.spawnError}`);
  if (r.timedOut) reasons.push(`timed out after ${timeoutSeconds}s`);
  if (!r.spawnError && !r.timedOut && r.exitCode !== 0) reasons.push(`claude exited ${r.exitCode}${r.stderr ? `: ${r.stderr}` : ''}`);
  if (r.parsed && r.parsed.is_error) reasons.push(`claude reported an error${r.parsed.subtype ? ` (${r.parsed.subtype})` : ''}`);
  if (r.costUsd !== null && r.costUsd > allowance) {
    const which = allowance === budget.perEvalUsd ? 'per-eval cap' : 'remaining-budget cap';
    reasons.push(`${which} exceeded: spent ${usd(r.costUsd)}, cap ${usd(allowance)}`);
  }
  const checks = runChecks(c.checks, { workdir: opts.workdir, resultText: r.resultText, timeoutSeconds });
  for (const k of checks) if (!k.passed) reasons.push(`check "${k.name}" (${k.kind}) failed: ${k.detail}`);
  // On any failure, show what claude said so the cause is readable without a rerun.
  if (reasons.length) {
    const said = r.resultText || r.stdoutExcerpt;
    reasons.push(said ? `claude said: ${said.slice(0, 300).replace(/\s+/g, ' ')}` : 'claude said nothing readable');
  }
  return { id: c.id, status: reasons.length ? 'failed' : 'passed', reasons, costUsd: r.costUsd, allowanceUsd: Number(allowance.toFixed(4)), checks };
}

function main() {
  let opts, budget, cases;
  try {
    opts = parseArgs(process.argv.slice(2));
    budget = loadBudget(opts.budget);
    cases = loadCases(opts.cases);
  } catch (e) {
    console.error(`evals: ${e.message}`);
    return 2;
  }

  // Default to a fresh temp directory so an eval never edits this repo or trips its scope hook.
  const tempWorkdir = opts.workdir === null;
  if (tempWorkdir) opts.workdir = fs.mkdtempSync(path.join(os.tmpdir(), 'evals-'));
  try { return runSuite({ opts, budget, cases }); }
  finally { if (tempWorkdir) fs.rmSync(opts.workdir, { recursive: true, force: true }); }
}

function runSuite({ opts, budget, cases }) {
  const ledger = new Ledger(budget, opts.monthSpent);
  const evals = [];
  let stop = null;

  for (const c of cases) {
    if (stop) { evals.push({ id: c.id, status: 'not-run', reasons: [stop], costUsd: null, checks: [] }); continue; }
    const allowance = ledger.allowance();
    if (allowance <= 0) {
      stop = ledger.describeStop();
      evals.push({ id: c.id, status: 'not-run', reasons: [stop], costUsd: null, checks: [] });
      continue;
    }
    const e = runEval(c, { allowance, opts, budget });
    ledger.record(e.costUsd);
    evals.push(e);
    console.log(`${e.status === 'passed' ? 'PASS' : 'FAIL'} ${e.id}  ${costText(e.costUsd)}`);
    for (const r of e.reasons) console.log(`  - ${r}`);
    if (ledger.allowance() <= 0 && !stop) stop = ledger.describeStop();
  }

  const notRun = evals.filter(e => e.status === 'not-run');
  for (const e of notRun) console.log(`NOT-RUN ${e.id}  counted as not passed`);
  if (stop && notRun.length) console.log(`${stop}; not run: ${notRun.map(e => e.id).join(', ')}`);
  else if (stop) console.log(`${stop}; no evals left to run`);

  const unknown = ledger.unknownCount;
  let suiteLine;
  if (unknown === 0) suiteLine = `suite spent: ${usd(ledger.measured)} [measured]`;
  else if (ledger.measured === 0) suiteLine = `suite spent: unknown [unknown] (${unknown} eval${unknown > 1 ? 's' : ''} with unreadable cost)`;
  else suiteLine = `suite spent: ${usd(ledger.measured)} [measured] plus ${unknown} unreadable`;
  console.log(suiteLine);
  if (unknown) console.log(`suite budget used, worst case: ${usd(ledger.used)} [not measured: each unreadable cost counted at the per-eval cap]`);
  console.log(`caps (proposed in epic #25, not measured): per-eval ${usd(budget.perEvalUsd)}, per-suite ${usd(budget.perSuiteUsd)}, monthly ${usd(budget.monthlyCeilingUsd)}`);
  console.log(opts.monthSpent === null ? 'monthly spend: unknown (pass --month-spent to enforce the monthly ceiling)' : `monthly spend: ${usd(opts.monthSpent)} before this run [supplied by caller]`);

  const passed = evals.filter(e => e.status === 'passed').length;
  const failed = evals.filter(e => e.status === 'failed').length;
  console.log(`${passed} passed, ${failed} failed, ${notRun.length} not run, of ${evals.length}`);

  if (opts.results) {
    const out = {
      finishedAt: new Date().toISOString(),
      caps: { perEvalUsd: budget.perEvalUsd, perSuiteUsd: budget.perSuiteUsd, monthlyCeilingUsd: budget.monthlyCeilingUsd, basis: 'estimate' },
      suite: { measuredUsd: unknown === 0 ? ledger.measured : (ledger.measured === 0 ? null : ledger.measured), unknownCostEvals: unknown,
        worstCaseUsd: ledger.used, monthSpentUsd: opts.monthSpent, stopped: stop },
      evals,
    };
    fs.mkdirSync(path.dirname(path.resolve(opts.results)), { recursive: true });
    fs.writeFileSync(opts.results, JSON.stringify(out, null, 2) + '\n');
  }

  return failed === 0 && notRun.length === 0 ? 0 : 1;
}

process.exitCode = main();
