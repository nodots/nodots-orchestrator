#!/usr/bin/env node
'use strict';
// Fixture test for evals/run.js --contract: the contract file reaches claude as
// --append-system-prompt for every case, and a run without it is unchanged.
// claude is the stub in evals/tests/stubs/claude.sh; no real model is called.
//
//   node evals/tests/contract-option.test.js
//
// Exit 0 when every check holds, 1 otherwise. Prints "--- N checks, M failed".

const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawnSync } = require('child_process');

const ROOT = path.resolve(__dirname, '../..');
const RUN = path.join(ROOT, 'evals/run.js');
const STUB = path.join(ROOT, 'evals/tests/stubs/claude.sh');

let run = 0, failed = 0;
function check(ok, label, detail) {
  run++;
  if (ok) { console.log(`  ok    ${label}`); return; }
  failed++;
  console.log(`  FAIL  ${label}`);
  if (detail) console.log(`        ${detail}`);
}
const eq = (want, got, label) => check(want === got, label, `expected [${want}], got [${got}]`);

const TMP = fs.mkdtempSync(path.join(os.tmpdir(), 'evals-contract-test-'));
const LOG = path.join(TMP, 'log');
const write = (rel, text) => fs.writeFileSync(path.join(TMP, rel), text);
fs.mkdirSync(path.join(TMP, 'work'));
fs.mkdirSync(path.join(TMP, 'cases'));
write('cases/a.json', '{"id":"a","prompt":"stub:cost=0.10","checks":[]}\n');
write('cases/b.json', '{"id":"b","prompt":"stub:cost=0.10","checks":[]}\n');
write('budget.json', '{"perEvalUsd":1,"perSuiteUsd":5,"monthlyCeilingUsd":50,"model":"sonnet"}\n');
const CONTRACT = '# Contract\n\nWrite the failing test before the change.\n';
write('contract.md', CONTRACT);
write('empty.md', '');

// The stub writes each argument on its own line to log/argv.N; read them back as one string.
const argv = n => { try { return fs.readFileSync(path.join(LOG, `argv.${n}`), 'utf8'); } catch (e) { return ''; } };
const invocations = () => (fs.existsSync(LOG) ? fs.readdirSync(LOG).filter(f => f.startsWith('argv')).length : 0);

function runner(...extra) {
  fs.rmSync(LOG, { recursive: true, force: true });
  const r = spawnSync('node', [RUN, '--claude', `bash ${STUB}`, '--workdir', path.join(TMP, 'work'),
    '--cases', path.join(TMP, 'cases'), '--budget', path.join(TMP, 'budget.json'), ...extra],
  { encoding: 'utf8', env: { ...process.env, EVAL_STUB_LOG: LOG } });
  return { rc: r.status, out: `${r.stdout}${r.stderr}` };
}

try {
  // 1. --contract: every case gets the file's text, verbatim, as --append-system-prompt.
  let r = runner('--contract', path.join(TMP, 'contract.md'));
  eq(0, r.rc, 'a run with --contract: exit 0');
  const want = `--append-system-prompt\n${CONTRACT}`;
  check(argv(1).includes(want), 'case a: claude gets the contract text as --append-system-prompt', argv(1));
  check(argv(2).includes(want), 'case b: claude gets the contract text as --append-system-prompt', argv(2));
  check(!argv(1).includes(path.join(TMP, 'contract.md')), 'the text is passed, not the path');

  // 2. Without --contract the argv is what it was before the option: no system prompt.
  r = runner();
  eq(0, r.rc, 'a run without --contract: exit 0');
  check(!argv(1).includes('--append-system-prompt'), 'no contract, no --append-system-prompt', argv(1));
  eq('-p stub:cost=0.10 --output-format json --max-budget-usd 1 --permission-mode acceptEdits --permission-prompts none --no-session-persistence --model sonnet',
    argv(1).trim().split('\n').join(' '), 'argv without --contract is unchanged');

  // 3. A contract that cannot be read is bad input: exit 2, file named, claude never runs.
  r = runner('--contract', path.join(TMP, 'missing.md'));
  eq(2, r.rc, 'a missing contract file: exit 2');
  check(r.out.includes(path.join(TMP, 'missing.md')), 'the missing file is named', r.out);
  eq(0, invocations(), 'claude is not invoked when the contract is missing');

  // 4. An empty contract is bad input, not a run with no contract.
  r = runner('--contract', path.join(TMP, 'empty.md'));
  eq(2, r.rc, 'an empty contract file: exit 2');
  check(r.out.includes('empty'), 'the output says the contract is empty', r.out);
  eq(0, invocations(), 'claude is not invoked when the contract is empty');
} finally {
  fs.rmSync(TMP, { recursive: true, force: true });
}

console.log(`  --- ${run} checks, ${failed} failed`);
process.exitCode = failed ? 1 : 0;
