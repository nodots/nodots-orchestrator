#!/usr/bin/env node
'use strict';
// Fixture test for the command-less lint check: it runs the checks[] commands of
// the work directory's .claude/standards.json, and fails with a named message when
// the manifest is absent or unparsable. claude is the stub in
// evals/tests/stubs/claude.sh; no real model is called.
//
//   node evals/tests/standards-check.test.js
//
// Exit 0 when every check holds, 1 otherwise. Prints "--- N checks, M failed".

const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawnSync } = require('child_process');

const ROOT = path.resolve(__dirname, '../..');
const RUN = path.join(ROOT, 'evals/run.js');
const STUB = path.join(ROOT, 'evals/tests/stubs/claude.sh');
const { validateCase } = require(path.join(ROOT, 'evals/lib/cases.js'));

let run = 0, failed = 0;
function check(ok, label, detail) {
  run++;
  if (ok) { console.log(`  ok    ${label}`); return; }
  failed++;
  console.log(`  FAIL  ${label}`);
  if (detail) console.log(`        ${detail}`);
}
const eq = (want, got, label) => check(want === got, label, `expected [${want}], got [${got}]`);

const TMP = fs.mkdtempSync(path.join(os.tmpdir(), 'evals-standards-test-'));
const LOG = path.join(TMP, 'log');
const WORK = path.join(TMP, 'work');
const write = (rel, text) => { fs.mkdirSync(path.dirname(path.join(TMP, rel)), { recursive: true }); fs.writeFileSync(path.join(TMP, rel), text); };
write('cases/a.json', '{"id":"a","prompt":"stub:cost=0.10","checks":[{"name":"repo checks","kind":"lint"}]}\n');
write('budget.json', '{"perEvalUsd":1,"perSuiteUsd":5,"monthlyCeilingUsd":50,"model":"sonnet"}\n');

function runner() {
  fs.rmSync(LOG, { recursive: true, force: true });
  const results = path.join(TMP, 'results.json');
  fs.rmSync(results, { force: true });
  const r = spawnSync('node', [RUN, '--claude', `bash ${STUB}`, '--workdir', WORK,
    '--cases', path.join(TMP, 'cases'), '--budget', path.join(TMP, 'budget.json'), '--results', results],
  { encoding: 'utf8', env: { ...process.env, EVAL_STUB_LOG: LOG } });
  return { rc: r.status, out: `${r.stdout}${r.stderr}` };
}

function freshWork(manifest) {
  fs.rmSync(WORK, { recursive: true, force: true });
  fs.mkdirSync(WORK);
  if (manifest !== undefined) write('work/.claude/standards.json', manifest);
}

try {
  // 1. A manifest whose checks exit 0: the command-less lint check runs them, in order, and passes.
  freshWork(JSON.stringify({ version: 1, checks: [
    { name: 'first', command: 'echo one >> ran' },
    { name: 'second', command: 'echo two >> ran' },
  ] }));
  let r = runner();
  eq(0, r.rc, 'a manifest whose checks exit 0: exit 0');
  check(r.out.includes('PASS a'), 'the case passes', r.out);
  const ran = fs.existsSync(path.join(WORK, 'ran')) ? fs.readFileSync(path.join(WORK, 'ran'), 'utf8') : '';
  eq('one\ntwo\n', ran, 'every manifest check ran in the work directory, in order');

  // 2. A failing manifest check: the first failure is named; later checks do not run.
  freshWork(JSON.stringify({ version: 1, checks: [
    { name: 'ok', command: 'true' },
    { name: 'broken', command: 'exit 4' },
    { name: 'later', command: ': > later' },
  ] }));
  r = runner();
  eq(1, r.rc, 'a failing manifest check: exit 1');
  check(r.out.includes('broken exited 4: exit 4'), 'the failing check is named with its exit code and command', r.out);
  check(!fs.existsSync(path.join(WORK, 'later')), 'checks after the first failure do not run');

  // 3. No manifest: the check fails with the named message.
  freshWork();
  r = runner();
  eq(1, r.rc, 'no manifest: exit 1');
  check(r.out.includes('no .claude/standards.json in the work directory'), 'the absent manifest is named', r.out);

  // 4. An unparsable manifest: the check fails with the parse error.
  freshWork('{ not json');
  r = runner();
  eq(1, r.rc, 'an unparsable manifest: exit 1');
  check(/\.claude\/standards\.json is not valid JSON: .+/.test(r.out), 'the parse error is reported', r.out);

  // 5. Load-time validation: command-less lint is valid; other kinds still need a command or regex.
  let err = '';
  try { validateCase({ id: 'x', prompt: 'p', checks: [{ name: 'repo checks', kind: 'lint' }] }, 'x.json'); }
  catch (e) { err = e.message; }
  eq('', err, 'a command-less lint check is valid at load');
  for (const kind of ['tests', 'policy']) {
    err = '';
    try { validateCase({ id: 'x', prompt: 'p', checks: [{ name: 'no command', kind }] }, 'x.json'); }
    catch (e) { err = e.message; }
    check(err.includes('needs command, resultMatches or resultNotMatches'), `a ${kind} check without a command is rejected at load`, err);
  }
} finally {
  fs.rmSync(TMP, { recursive: true, force: true });
}

console.log(`  --- ${run} checks, ${failed} failed`);
process.exitCode = failed ? 1 : 0;
