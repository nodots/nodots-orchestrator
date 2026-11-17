#!/usr/bin/env node
'use strict';

/*
 * run-checks.js — run the checks a repo's standards manifest names.
 *
 * The commands come from the *base* ref's .claude/standards.json, never the
 * head's, so a pull request cannot change what it is checked by. The head's
 * manifest is still validated: a PR that breaks the manifest fails here.
 *
 * No dependencies, like check-standards.js, whose validator this reuses.
 *
 * CLI:
 *   node run-checks.js [--root <dir>] [--base <ref>]
 *   --root  the repo to check; defaults to the cwd
 *   --base  the ref whose manifest supplies checks[]; defaults to HEAD
 *
 *   Each base check runs in manifest order as `sh -c <command>` with cwd
 *   <root>, its stdout and stderr passed through, followed by
 *   "PASS  <name>" or "FAIL  <name> (exit <n>)". Every check runs, even after
 *   a failure. The last line is
 *   "run-checks: <k> of <n> checks passed (manifest from <base>)".
 *
 *   exit 0  every check passed
 *   exit 1  at least one check failed
 *   exit 2  the head manifest is missing or invalid, the base cannot be
 *           resolved, or the base manifest is missing or invalid; no check runs
 *
 *   Warnings from either validation go to stderr and never change the exit code.
 */

const fs = require('fs');
const path = require('path');
const { execFileSync, spawnSync } = require('child_process');
const { validateStandards, validateFile } = require(path.join(__dirname, 'check-standards.js'));

const MANIFEST = '.claude/standards.json';
const USAGE = 'run-checks: usage: run-checks.js [--root <dir>] [--base <ref>]\n';

const out = (s) => fs.writeSync(1, s);
const err = (s) => fs.writeSync(2, s);

function git(root, args) {
  return execFileSync('git', ['-C', root, ...args], {
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'pipe'],
    maxBuffer: 64 * 1024 * 1024,
  });
}

// The base manifest and its tree's file list. Returns { text, files } or
// { error } naming why the base cannot supply a manifest.
function readBase(root, base) {
  try {
    git(root, ['rev-parse', '--verify', '--quiet', `${base}^{commit}`]);
  } catch (e) {
    return { error: `run-checks: cannot resolve base ${base}` };
  }
  let files;
  try {
    files = git(root, ['ls-tree', '-r', '-z', '--name-only', base]).split('\0').filter(Boolean);
  } catch (e) {
    return { error: `run-checks: cannot list the tree of ${base}: ${String(e.stderr || e.message).trim()}` };
  }
  if (!files.includes(MANIFEST)) return { error: `run-checks: no ${MANIFEST} at ${base}` };
  let text;
  try {
    text = git(root, ['show', `${base}:${MANIFEST}`]);
  } catch (e) {
    return { error: `run-checks: cannot read ${base}:${MANIFEST}: ${String(e.stderr || e.message).trim()}` };
  }
  return { text, files };
}

function runCheck(root, check) {
  const r = spawnSync('sh', ['-c', check.command], { cwd: root, stdio: 'inherit' });
  if (r.error) return `FAIL  ${check.name} (could not start sh: ${r.error.message})`;
  if (r.signal) return `FAIL  ${check.name} (signal ${r.signal})`;
  if (r.status !== 0) return `FAIL  ${check.name} (exit ${r.status})`;
  return null;
}

function main(argv) {
  let root = process.cwd();
  let base = 'HEAD';
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--root' && i + 1 < argv.length) root = argv[++i];
    else if (a === '--base' && i + 1 < argv.length) base = argv[++i];
    else { err(USAGE); return 2; }
  }

  // The head: validated exactly as check-standards.js validates it.
  const head = validateFile(root, MANIFEST);
  for (const w of head.warnings) err(`standards: ${w}\n`);
  if (!head.ok) {
    for (const d of head.defects) err(`standards: ${MANIFEST}: ${d}\n`);
    return 2;
  }

  // The base: the manifest whose checks run.
  const b = readBase(root, base);
  if (b.error) { err(`${b.error}\n`); return 2; }
  const where = `${base}:${MANIFEST}`;
  const res = validateStandards({ text: b.text, files: b.files });
  for (const w of res.warnings) err(`standards: ${where}: ${w}\n`);
  if (!res.ok) {
    for (const d of res.defects) err(`standards: ${where}: ${d}\n`);
    return 2;
  }

  const checks = res.manifest.checks;
  let passed = 0;
  for (const c of checks) {
    const failure = runCheck(root, c);
    if (failure) out(`${failure}\n`);
    else { passed++; out(`PASS  ${c.name}\n`); }
  }
  out(`run-checks: ${passed} of ${checks.length} checks passed (manifest from ${base})\n`);
  return passed === checks.length ? 0 : 1;
}

if (require.main === module) process.exitCode = main(process.argv.slice(2));
