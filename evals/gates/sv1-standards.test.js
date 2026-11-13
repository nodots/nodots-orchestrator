#!/usr/bin/env node
'use strict';
// SV1 gate, eval side: the eval runner runs the same manifest checks the
// launcher briefs. Under the claude stub (evals/tests/stubs/claude.sh), the
// case evals/cases/contract-runs-standards-checks.json loads and runs through
// evals/run.js; with the work directory prepared the way the case's prompt
// describes, its command-less lint check runs the manifest's lint.sh and
// passes, and with the manifest removed it fails with the named message.
// No model is called. The gate edits nothing it verifies: it reads the case
// and copies it into a temporary cases directory.
//
//   node evals/gates/sv1-standards.test.js
//
// Exit 0 when every check holds, 1 otherwise. Prints "--- N checks, M failed".

const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawnSync } = require('child_process');

const ROOT = path.resolve(__dirname, '../..');
const RUN = path.join(ROOT, 'evals/run.js');
const STUB = path.join(ROOT, 'evals/tests/stubs/claude.sh');
const CASE_FILE = path.join(ROOT, 'evals/cases/contract-runs-standards-checks.json');
const { loadCases } = require(path.join(ROOT, 'evals/lib/cases.js'));

let run = 0, failed = 0;
function check(ok, label, detail) {
  run++;
  if (ok) { console.log(`  ok    ${label}`); return; }
  failed++;
  console.log(`  FAIL  ${label}`);
  if (detail) console.log(`        ${detail}`);
}
const eq = (want, got, label) => check(JSON.stringify(want) === JSON.stringify(got), label, `expected ${JSON.stringify(want)}, got ${JSON.stringify(got)}`);

const TMP = fs.mkdtempSync(path.join(os.tmpdir(), 'evals-sv1-gate-'));
const CASES = path.join(TMP, 'cases');
const WORK = path.join(TMP, 'work');
const LOG = path.join(TMP, 'log');
const RESULTS = path.join(TMP, 'results.json');
const BUDGET = path.join(TMP, 'budget.json');

const git = (...args) => {
  const r = spawnSync('git', ['-c', 'user.name=fixture', '-c', 'user.email=f@example.invalid', ...args], { cwd: WORK, encoding: 'utf8' });
  if (r.status !== 0) throw new Error(`git ${args.join(' ')} failed in ${WORK}: ${r.stderr}`);
};

// The setup the case's prompt describes, done here in its place: git init;
// greeting.txt with `hello`; lint.sh with `echo ran >> .standards-ran` and
// `exit 0`; .claude/standards.json naming lint: bash lint.sh; one commit.
// lintBody overrides lint.sh for the control; withManifest false omits it.
function prepare({ withManifest = true, lintBody = 'echo ran >> .standards-ran\nexit 0\n' } = {}) {
  fs.rmSync(WORK, { recursive: true, force: true });
  fs.mkdirSync(WORK);
  git('init', '-q');
  fs.writeFileSync(path.join(WORK, 'greeting.txt'), 'hello\n');
  fs.writeFileSync(path.join(WORK, 'lint.sh'), lintBody);
  if (withManifest) {
    fs.mkdirSync(path.join(WORK, '.claude'));
    fs.writeFileSync(path.join(WORK, '.claude/standards.json'), '{"version": 1, "checks": [{"name": "lint", "command": "bash lint.sh"}]}\n');
  }
  git('add', '-A');
  git('commit', '-q', '-m', 'first');
}

function runner() {
  fs.rmSync(LOG, { recursive: true, force: true });
  fs.rmSync(RESULTS, { force: true });
  const r = spawnSync('node', [RUN, '--claude', `bash ${STUB}`, '--workdir', WORK,
    '--cases', CASES, '--budget', BUDGET, '--results', RESULTS],
  { encoding: 'utf8', env: { ...process.env, EVAL_STUB_LOG: LOG } });
  const results = fs.existsSync(RESULTS) ? JSON.parse(fs.readFileSync(RESULTS, 'utf8')) : null;
  const e = results && results.evals.find(x => x.id === 'contract-runs-standards-checks');
  const lint = e ? e.checks.find(k => k.kind === 'lint') : null;
  return { rc: r.status, out: `${r.stdout}${r.stderr}`, e, lint };
}

try {
  // 1. The case loads, and its lint check is the command-less kind.
  const caseText = fs.readFileSync(CASE_FILE, 'utf8');
  fs.mkdirSync(CASES);
  fs.writeFileSync(path.join(CASES, path.basename(CASE_FILE)), caseText);
  fs.writeFileSync(BUDGET, '{"perEvalUsd":1,"perSuiteUsd":5,"monthlyCeilingUsd":50,"model":"sonnet"}\n');
  let cases = [];
  let err = '';
  try { cases = loadCases(CASES); } catch (e) { err = e.message; }
  eq('', err, 'the case loads');
  eq(['contract-runs-standards-checks'], cases.map(c => c.id), 'the cases directory holds the one case');
  const lints = (cases[0] ? cases[0].checks : []).filter(k => k.kind === 'lint');
  eq(1, lints.length, 'the case has one lint check');
  check(lints.length === 1 && !lints[0].command && lints[0].resultMatches === undefined && lints[0].resultNotMatches === undefined,
    'the lint check is command-less: no command, no regex', JSON.stringify(lints[0]));
  check(cases[0] && /lint\.sh/.test(cases[0].prompt) && /\.claude\/standards\.json/.test(cases[0].prompt),
    'the prompt describes lint.sh and .claude/standards.json, the setup prepared here');

  // 2. Prepared as the prompt describes: the lint check runs lint.sh and passes.
  //    The stub runs nothing, so "the worker ran the manifest's checks" fails;
  //    that is the stub, not the lint check, and it shows lint.sh had not run
  //    before the lint check ran it.
  prepare();
  let r = runner();
  check(r.e !== undefined && r.e !== null, 'the runner ran the case under the stub', r.out);
  check(fs.existsSync(path.join(LOG, 'argv.1')), 'the stub was invoked', r.out);
  eq(true, r.lint && r.lint.passed, 'with the manifest: the command-less lint check passes');
  eq('', r.lint && r.lint.detail, 'with the manifest: the lint check reports no problem');
  const ranFirst = r.e && r.e.checks.find(k => k.name === 'the worker ran the manifest\'s checks');
  eq(false, ranFirst && ranFirst.passed, 'the stub did not run lint.sh, so the worker-ran check fails before the lint check runs');

  // 3. Control: the same setup with a lint.sh that exits 1. The lint check
  //    fails naming the manifest check and its command, so it is lint.sh that
  //    decided the pass in 2.
  prepare({ lintBody: 'echo ran >> .standards-ran\nexit 1\n' });
  r = runner();
  eq(false, r.lint && r.lint.passed, 'control: a lint.sh that exits 1 fails the lint check');
  eq('lint exited 1: bash lint.sh', r.lint && r.lint.detail, 'control: the failure names the manifest check and its command');

  // 4. Manifest removed: the lint check fails with the named message.
  prepare({ withManifest: false });
  r = runner();
  eq(1, r.rc, 'without the manifest: the runner exits 1');
  eq(false, r.lint && r.lint.passed, 'without the manifest: the lint check fails');
  eq('no .claude/standards.json in the work directory', r.lint && r.lint.detail, 'without the manifest: the failure is the named message');
  check(r.out.includes('(lint) failed: no .claude/standards.json in the work directory'), 'the runner output names it', r.out);

  // 5. The gate edited nothing it verifies.
  eq(caseText, fs.readFileSync(CASE_FILE, 'utf8'), 'the case file is unchanged');
} finally {
  fs.rmSync(TMP, { recursive: true, force: true });
}

console.log(`  --- ${run} checks, ${failed} failed`);
process.exitCode = failed ? 1 : 0;
