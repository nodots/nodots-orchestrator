#!/usr/bin/env node
'use strict';

/*
 * Pre-commit scope check (opt-in; self-contained; Node builtins only).
 *
 * Refuses a commit whose staged files fall outside the active work package's
 * SCOPE.json allowedPaths, or match forbiddenPaths. It is the commit-time
 * counterpart of enforce-scope.js: that hook judges Edit and Write, this one
 * judges what is about to be committed, so it also catches writes that went
 * through a shell command. No SCOPE.json present => no restriction.
 *
 * Control header
 * --------------
 * Default: deny. A commit with an out-of-lane file exits 1 and lists every
 *   offending file. Nothing is staged, unstaged or reverted on the caller's
 *   behalf.
 * Fail posture: open, and loud. Any error evaluating the lane exits 0 after
 *   one stderr line naming this script and the error, for the same reason as
 *   enforce-scope.js: a coordination guardrail must not halt a fleet, and a
 *   silent exit 0 is indistinguishable from "in lane".
 * Residue — what this does not judge: a commit made with `--no-verify`, a
 *   write that is never staged, and file contents. It judges paths only.
 *
 * Lane resolution is identical to enforce-scope.js: SCOPE.json from
 * .agentic/cells/<branch>/, then .auto-shop/cells/<branch>/, then the repo
 * root. SCOPE.json, HANDOFF.md and BLOCKER.md are always committable. Keep the
 * glob and the resolution in step with enforce-scope.js.
 *
 * Wire it up as a git pre-commit hook, for example in .husky/pre-commit:
 *   node .claude/hooks/enforce-scope-staged.js
 */

const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');

const HOOK = 'enforce-scope-staged';
const ARTIFACTS = { scope: 'SCOPE.json', handoff: 'HANDOFF.md', blocker: 'BLOCKER.md' };
const CELL_DIRS = ['.agentic', '.auto-shop'];

function git(dir, args) {
  return execFileSync('git', ['-C', dir, ...args], {
    encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'],
  });
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

try {
  const root = git(process.cwd(), ['rev-parse', '--show-toplevel']).trim();
  let branch = null;
  try { branch = git(root, ['rev-parse', '--abbrev-ref', 'HEAD']).trim(); } catch { /* no commits yet */ }

  const scopePath = artifactPath(root, 'scope', branch);
  if (!fs.existsSync(scopePath)) process.exit(0); // no scope => unrestricted

  const scope = JSON.parse(fs.readFileSync(scopePath, 'utf8'));
  const allowedPaths = Array.isArray(scope.allowedPaths) ? scope.allowedPaths : [];
  const forbiddenPaths = Array.isArray(scope.forbiddenPaths) ? scope.forbiddenPaths : [];
  const coordination = coordinationPaths(root, branch);

  // -z: NUL-separated, so a path with spaces or quotes is not escaped.
  const staged = git(root, ['diff', '--cached', '--name-only', '-z'])
    .split('\0').filter(Boolean);

  const violations = [];
  for (const file of staged) {
    if (coordination.has(file)) continue;
    if (matchesAny(forbiddenPaths, file)) {
      violations.push({ file, why: 'matches forbiddenPaths' });
    } else if (allowedPaths.length === 0 || !matchesAny(allowedPaths, file)) {
      violations.push({ file, why: 'not in allowedPaths' });
    }
  }

  if (violations.length > 0) {
    const rel = path.relative(root, scopePath).split(path.sep).join('/');
    process.stderr.write(
      `Scope violation: staged files outside the lane in ${rel}:\n` +
      violations.map(v => `  ${v.file} (${v.why})`).join('\n') + '\n' +
      `Unstage them, or stop and write BLOCKER.md if the lane is wrong. ` +
      `Do not edit SCOPE.json to fit the change.\n`
    );
    process.exit(1);
  }
  process.exit(0);
} catch (err) {
  try {
    process.stderr.write(
      `${HOOK}: could not evaluate the scope lane, allowing this commit. ` +
      `${(err && err.message) || err}\n`
    );
  } catch { /* stderr gone; nothing further this hook can do */ }
  process.exit(0);
}
