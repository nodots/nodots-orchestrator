#!/usr/bin/env node
'use strict';

/*
 * PreToolUse scope-enforcement hook (self-contained; Node builtins only).
 *
 * Blocks Edit/Write to files outside the active work package's SCOPE.json
 * allowedPaths (or matching forbiddenPaths). No SCOPE.json present => no
 * restriction, so the default branch and ad-hoc work are unaffected.
 *
 * SCOPE.json is resolved from, in order:
 *   1. .agentic/cells/<branch>/SCOPE.json    (branch-scoped, preferred)
 *   2. .auto-shop/cells/<branch>/SCOPE.json  (legacy branch-scoped)
 *   3. <repoRoot>/SCOPE.json                 (root fallback)
 *
 * Coordination files (SCOPE.json/HANDOFF.md/BLOCKER.md) are always writable.
 *
 * Wire it up in .claude/settings.json:
 *   { "hooks": { "PreToolUse": [ { "matcher": "Edit|Write",
 *       "hooks": [ { "type": "command",
 *                    "command": "node .claude/hooks/enforce-scope.js" } ] } ] } }
 */

const fs = require('fs');
const path = require('path');
const { execSync } = require('child_process');

const ARTIFACTS = { scope: 'SCOPE.json', handoff: 'HANDOFF.md', blocker: 'BLOCKER.md' };
const CELL_DIRS = ['.agentic', '.auto-shop'];

function currentBranch(root) {
  try {
    return execSync(`git -C "${root}" rev-parse --abbrev-ref HEAD`, {
      encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'],
    }).trim();
  } catch { return null; }
}

function branchDirs(root, branch) {
  if (!branch || branch === 'HEAD') return [];
  const parts = branch.split('/').filter(Boolean);
  return CELL_DIRS.map(d => path.join(root, d, 'cells', ...parts));
}

function artifactPath(root, kind, branch) {
  const name = ARTIFACTS[kind];
  for (const bdir of branchDirs(root, branch)) {
    const p = path.join(bdir, name);
    if (fs.existsSync(p)) return p;
  }
  const rootPath = path.join(root, name);
  if (fs.existsSync(rootPath)) return rootPath;
  const [preferred] = branchDirs(root, branch);
  return preferred ? path.join(preferred, name) : rootPath;
}

function coordinationPaths(root, branch) {
  const allowed = new Set();
  for (const kind of Object.keys(ARTIFACTS)) {
    allowed.add(ARTIFACTS[kind]);
    allowed.add(path.relative(root, artifactPath(root, kind, branch)).split(path.sep).join('/'));
    for (const bdir of branchDirs(root, branch)) {
      allowed.add(path.relative(root, path.join(bdir, ARTIFACTS[kind])).split(path.sep).join('/'));
    }
  }
  return allowed;
}

// Minimal glob -> RegExp: supports **, **/ (zero-or-more dirs), *, ?, literals.
function globToRegExp(glob) {
  let re = '';
  for (let i = 0; i < glob.length; i++) {
    const c = glob[i];
    if (c === '*') {
      if (glob[i + 1] === '*') {
        if (glob[i + 2] === '/') { re += '(?:.*/)?'; i += 2; }
        else { re += '.*'; i += 1; }
      } else { re += '[^/]*'; }
    } else if (c === '?') {
      re += '[^/]';
    } else if ('\\^$.|+()[]{}'.includes(c)) {
      re += '\\' + c;
    } else { re += c; }
  }
  return new RegExp('^' + re + '$');
}

function matchesAny(patterns, rel) {
  return patterns.some(p => globToRegExp(p).test(rel));
}

let input = '';
process.stdin.setEncoding('utf8');
process.stdin.on('data', c => { input += c; });
process.stdin.on('end', () => {
  try {
    const event = JSON.parse(input);
    const filePath = event.tool_input && event.tool_input.file_path;
    if (!filePath) process.exit(0);

    const root = path.resolve(__dirname, '..', '..'); // .claude/hooks/ -> repo root
    const branch = currentBranch(root);
    const scopePath = artifactPath(root, 'scope', branch);
    if (!fs.existsSync(scopePath)) process.exit(0); // no scope => unrestricted

    const scope = JSON.parse(fs.readFileSync(scopePath, 'utf8'));
    const rel = path.relative(root, path.resolve(filePath)).split(path.sep).join('/');
    if (rel.startsWith('..')) process.exit(0); // outside repo

    if (coordinationPaths(root, branch).has(rel)) process.exit(0);

    const allowed = Array.isArray(scope.allowedPaths) && scope.allowedPaths.length > 0 &&
      matchesAny(scope.allowedPaths, rel);
    const forbidden = Array.isArray(scope.forbiddenPaths) && matchesAny(scope.forbiddenPaths, rel);

    if (!allowed || forbidden) {
      process.stderr.write(
        `Scope violation: ${rel} is outside this work package's SCOPE.json allowedPaths ` +
        `(or matches forbiddenPaths). If you genuinely need this file, stop and write BLOCKER.md ` +
        `explaining why, rather than editing outside your lane.`
      );
      process.exit(2); // non-zero blocks the tool call
    }
    process.exit(0);
  } catch {
    process.exit(0); // fail open: never block on hook error
  }
});
