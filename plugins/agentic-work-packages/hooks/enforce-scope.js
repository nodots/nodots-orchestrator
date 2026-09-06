#!/usr/bin/env node
'use strict';

/*
 * PreToolUse scope-enforcement hook (self-contained; Node builtins only).
 *
 * Blocks Edit/Write to files outside the active work package's SCOPE.json
 * allowedPaths (or matching forbiddenPaths). No SCOPE.json present => no
 * restriction, so the default branch and ad-hoc work are unaffected.
 *
 * Control header
 * --------------
 * Default: deny. An out-of-lane write is refused with the blocker instruction.
 *   It is never a permission ask: an ask hands the confined worker the
 *   click-through on its own confinement, and it wedges an unattended run on a
 *   prompt nobody is there to answer.
 * Fail posture: open, and loud. Any error evaluating the lane exits 0 after
 *   one stderr line naming this hook and the error. Open, because this is a
 *   coordination guardrail and not a security control, and a hook that cannot
 *   evaluate must not halt a fleet. Loud, because a sensor that cannot
 *   evaluate has to say so — a silent exit 0 is indistinguishable from "in
 *   lane".
 * Residue — the input classes this hook does not judge: writes mediated by
 *   Bash (`sed -i`, `tee`, shell redirects, `python -c`), MCP filesystem
 *   tools, and the NotebookEdit and MultiEdit tools. The matcher `Edit|Write`
 *   contains only exact-match characters, so it matches those two tool names
 *   and nothing else; no other tool reaches this hook at all. An agent routing
 *   around its lane through any of these is a coordination signal, not a
 *   threat model.
 *
 * Repo root
 * ---------
 * Resolved from the hook input's `cwd` field, via
 * `git -C <cwd> rev-parse --show-toplevel`. Only when `cwd` is absent does the
 * root fall back to this file's own location (`<here>/../..`), which is right
 * for a manual `.claude/hooks/` install and wrong under a plugin install,
 * where the file lives outside the repo entirely. In a linked worktree
 * `--show-toplevel` returns the worktree root, which is where that worker's
 * SCOPE.json lives, so worktree isolation is preserved.
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
const { execFileSync } = require('child_process');

const HOOK = 'enforce-scope';
const ARTIFACTS = { scope: 'SCOPE.json', handoff: 'HANDOFF.md', blocker: 'BLOCKER.md' };
const CELL_DIRS = ['.agentic', '.auto-shop'];

// execFile, not a shell string: `dir` comes from the hook input and must never
// be interpolated into a command line.
function git(dir, args) {
  return execFileSync('git', ['-C', dir, ...args], {
    encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'],
  }).trim();
}

function repoRoot(cwd) {
  if (cwd) {
    try {
      const top = git(cwd, ['rev-parse', '--show-toplevel']);
      if (top) return top;
    } catch { /* not a repo, or no git on PATH: fall through */ }
  }
  return path.resolve(__dirname, '..', '..'); // .claude/hooks/ -> repo root
}

function currentBranch(root) {
  try {
    return git(root, ['rev-parse', '--abbrev-ref', 'HEAD']);
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

    const root = repoRoot(event.cwd);
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
      // Deny, never ask: stderr carries the reason, exit 2 blocks the call.
      process.stderr.write(
        `Scope violation: ${rel} is outside this work package's SCOPE.json allowedPaths ` +
        `(or matches forbiddenPaths). If you genuinely need this file, stop and write BLOCKER.md ` +
        `explaining why, rather than editing outside your lane.`
      );
      process.exit(2); // non-zero blocks the tool call
    }
    process.exit(0);
  } catch (err) {
    // Fail open, but never silently.
    try {
      process.stderr.write(
        `${HOOK}: could not evaluate the scope lane, allowing this write. ` +
        `${(err && err.message) || err}\n`
      );
    } catch { /* stderr gone; there is nothing further this hook can do */ }
    process.exit(0);
  }
});
