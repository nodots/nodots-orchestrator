'use strict';
// Run claude -p once per eval, read its cost, and run the case's checks.

const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');

// Cost from claude's --output-format json output: one result object, or JSON lines
// whose last "result" line counts (the fleet stub prints that shape). Anything
// else is null, meaning unknown. Never 0.
function parseResult(stdout) {
  const text = String(stdout || '').trim();
  const candidates = [text, ...text.split('\n').reverse()];
  for (const c of candidates) {
    let o;
    try { o = JSON.parse(c); } catch (e) { continue; }
    if (o && typeof o === 'object' && (o.type === 'result' || 'total_cost_usd' in o || 'result' in o)) return o;
  }
  return null;
}

function readCost(parsed) {
  if (!parsed) return null;
  const c = parsed.total_cost_usd;
  return typeof c === 'number' && Number.isFinite(c) && c >= 0 ? c : null;
}

function runClaude({ bin, prompt, allowance, model, permissionMode, workdir, timeoutSeconds, systemPrompt }) {
  const args = ['-p', prompt, '--output-format', 'json', '--max-budget-usd', String(Number(allowance.toFixed(4))),
    '--permission-mode', permissionMode, '--permission-prompts', 'none', '--no-session-persistence'];
  if (model) args.push('--model', model);
  if (systemPrompt) args.push('--append-system-prompt', systemPrompt);   // the --contract text (evals/run.js)
  const env = { ...process.env };
  delete env.CLAUDECODE;               // nested-session guard; each eval is its own session (as in plugins/fleet/src/launch.js)
  const [cmd, ...lead] = bin.split(/\s+/).filter(Boolean);   // bin may carry leading arguments, e.g. "bash stub.sh"
  const r = spawnSync(cmd, [...lead, ...args], { cwd: workdir, env, encoding: 'utf8', timeout: timeoutSeconds * 1000, maxBuffer: 64 * 1024 * 1024 });
  const parsed = parseResult(r.stdout);
  return {
    exitCode: r.status,
    timedOut: !!(r.error && r.error.code === 'ETIMEDOUT'),
    spawnError: r.error && r.error.code !== 'ETIMEDOUT' ? r.error.message : null,
    stderr: String(r.stderr || '').trim().slice(0, 500),
    parsed,
    costUsd: readCost(parsed),
    resultText: parsed && typeof parsed.result === 'string' ? parsed.result : '',
    stdoutExcerpt: parsed ? '' : String(r.stdout || '').trim().slice(0, 300),
  };
}

// A lint check with no command and no regex runs every checks[].command in the work
// directory's .claude/standards.json, in order, stopping at the first that fails.
// The manifest is not validated: the eval asserts behavior, not manifest validity.
function runManifestChecks(workdir, timeoutSeconds) {
  const file = path.join(workdir, '.claude', 'standards.json');
  let text;
  try { text = fs.readFileSync(file, 'utf8'); }
  catch (e) {
    if (e.code === 'ENOENT') return 'no .claude/standards.json in the work directory';
    return `cannot read .claude/standards.json: ${e.message}`;
  }
  let manifest;
  try { manifest = JSON.parse(text); }
  catch (e) { return `.claude/standards.json is not valid JSON: ${e.message}`; }
  const list = manifest && Array.isArray(manifest.checks) ? manifest.checks : null;
  if (!list) return '.claude/standards.json has no checks array';
  for (const c of list) {
    const name = c && c.name;
    if (!c || typeof c.command !== 'string') return `${name} has no command`;
    const r = spawnSync('bash', ['-c', c.command], { cwd: workdir, encoding: 'utf8', timeout: timeoutSeconds * 1000 });
    if (r.status !== 0) return `${name} exited ${r.status === null ? 'abnormally' : r.status}: ${c.command}`;
  }
  return null;
}

function runChecks(checks, { workdir, resultText, timeoutSeconds }) {
  return checks.map(k => {
    const problems = [];
    if (k.kind === 'lint' && !k.command && k.resultMatches === undefined && k.resultNotMatches === undefined) {
      const problem = runManifestChecks(workdir, timeoutSeconds);
      if (problem) problems.push(problem);
    }
    if (k.command) {
      const r = spawnSync('bash', ['-c', k.command], { cwd: workdir, encoding: 'utf8', timeout: timeoutSeconds * 1000 });
      if (r.status !== 0) problems.push(`command exited ${r.status === null ? 'abnormally' : r.status}: ${k.command}`);
    }
    if (k.resultMatches !== undefined && !new RegExp(k.resultMatches).test(resultText)) problems.push(`result does not match /${k.resultMatches}/`);
    if (k.resultNotMatches !== undefined && new RegExp(k.resultNotMatches).test(resultText)) problems.push(`result matches /${k.resultNotMatches}/`);
    return { name: k.name, kind: k.kind, passed: problems.length === 0, detail: problems.join('; ') };
  });
}

module.exports = { runClaude, runChecks, parseResult, readCost };
