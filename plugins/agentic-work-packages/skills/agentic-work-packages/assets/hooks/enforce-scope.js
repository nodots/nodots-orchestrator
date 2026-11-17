#!/usr/bin/env node
'use strict';

/*
 * Scope-enforcement hook (self-contained; Node builtins only). Two modes.
 *
 * PreToolUse, Edit|Write: blocks a write to a file outside the active work
 * package's SCOPE.json allowedPaths (or matching forbiddenPaths), before it
 * happens.
 *
 * PostToolUse, Bash: after each Bash call, lists every path the branch changes
 * — `git status --porcelain -z` (staged, unstaged, untracked) plus
 * `git diff --name-only <merge-base> HEAD` for commits, the merge base taken
 * against the lane's baseBranch when SCOPE.json names one, else the nearest
 * integration branch — and judges each with the same
 * matcher. It reads the worktree's actual state and never parses the command,
 * so it does not depend on shell grammar. An out-of-lane path returns a block
 * decision naming each path, telling the worker to revert it or stop and write
 * BLOCKER.md. The write has already happened; the block is what makes the
 * worker see it right after the call that made it.
 *
 * No SCOPE.json present => no restriction in either mode, so the default
 * branch and ad-hoc work are unaffected.
 *
 * Control header
 * --------------
 * Default: deny. An out-of-lane Edit or Write is refused with the blocker
 *   instruction, and an out-of-lane change after a Bash call is a block
 *   decision. Neither is ever a permission ask: an ask hands the confined
 *   worker the click-through on its own confinement, and it wedges an
 *   unattended run on a prompt nobody is there to answer.
 * Fail posture: open, and loud. Any error evaluating the lane exits 0 after
 *   one stderr line naming this hook and the error. Open, because this is a
 *   coordination guardrail and not a security control, and a hook that cannot
 *   evaluate must not halt a fleet. Loud, because a sensor that cannot
 *   evaluate has to say so — a silent exit 0 is indistinguishable from "in
 *   lane".
 * Residue — what is still not caught: writes outside the worktree; a change
 *   made and reverted within one Bash call; a gitignored path; commits, when
 *   the repo has no integration branch (origin/HEAD, development, develop,
 *   main, master) to take a merge base from; and the tools neither matcher
 *   names — MCP filesystem tools, NotebookEdit, MultiEdit — until the next
 *   Bash call, or the stop, where require-handoff.js runs the same lane check.
 *   An agent routing around its lane is a coordination signal, not a threat
 *   model.
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
 *   { "hooks": {
 *       "PreToolUse": [ { "matcher": "Edit|Write",
 *         "hooks": [ { "type": "command",
 *                      "command": "node .claude/hooks/enforce-scope.js" } ] } ],
 *       "PostToolUse": [ { "matcher": "Bash",
 *         "hooks": [ { "type": "command",
 *                      "command": "node .claude/hooks/enforce-scope.js" } ] } ] } }
 */

const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');

const HOOK = 'enforce-scope';

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

// --- lane matcher: begin -----------------------------------------------------
// Copied verbatim into enforce-scope.js and require-handoff.js, because each
// hook is self-contained (Node builtins only). A test keeps the two copies
// identical: change both or neither.
const ARTIFACTS = { scope: 'SCOPE.json', handoff: 'HANDOFF.md', blocker: 'BLOCKER.md' };
const CELL_DIRS = ['.agentic', '.auto-shop'];
// The integration branches a package branch is measured from.
const LANE_BASES = ['development', 'develop', 'main', 'master'];

// Untrimmed: porcelain output can start with a space that belongs to the first
// entry's status column.
function laneGit(dir, args) {
  return execFileSync('git', ['-C', dir, ...args], {
    encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'], maxBuffer: 64 * 1024 * 1024,
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

// The merge base with the branch the lane names as its baseBranch: against
// origin/<baseBranch>, else refs/heads/<baseBranch>. Without one, or when
// neither ref exists, the merge base with the nearest integration branch: of
// origin/HEAD and the LANE_BASES names, local or on origin, the one HEAD is
// fewest commits ahead of. Nearest rather than the remote default, because a
// default that lags the integration branch would count every package merged
// since as this branch's change. null when there is no other branch to measure
// from.
function laneMergeBase(root, branch, baseBranch) {
  if (typeof baseBranch === 'string' && baseBranch) {
    for (const ref of [`refs/remotes/origin/${baseBranch}`, `refs/heads/${baseBranch}`]) {
      try {
        return laneGit(root, ['merge-base', 'HEAD', ref]).trim();
      } catch { /* no such ref, or no common history: try the next */ }
    }
  }
  const refs = ['refs/remotes/origin/HEAD'];
  for (const name of LANE_BASES) {
    if (name === branch) continue;
    refs.push(`refs/remotes/origin/${name}`, `refs/heads/${name}`);
  }
  let best = null;
  for (const ref of refs) {
    let base;
    try {
      base = laneGit(root, ['merge-base', 'HEAD', ref]).trim();
    } catch { continue; } // no such ref, no commits yet, or no common history
    const ahead = Number(laneGit(root, ['rev-list', '--count', `${base}..HEAD`]).trim());
    if (!best || ahead < best.ahead) best = { base, ahead };
  }
  return best ? best.base : null;
}

// Every path the branch changes, read from the worktree's state and never from
// a command line: committed since the merge base, staged, unstaged and
// untracked, with both sides of a rename. Ignored files are not listed.
function laneChanges(root, branch, baseBranch) {
  const files = new Set();
  const status = laneGit(root, ['status', '--porcelain', '-z', '--untracked-files=all', '--no-renames']);
  for (const entry of status.split('\0')) {
    if (entry.length > 3) files.add(entry.slice(3)); // "XY <path>"
  }
  const base = laneMergeBase(root, branch, baseBranch);
  if (base) {
    const committed = laneGit(root, ['diff', '--name-only', '-z', '--no-renames', base, 'HEAD']);
    for (const file of committed.split('\0')) if (file) files.add(file);
  }
  return [...files].sort();
}

// null when no SCOPE.json governs the branch. Otherwise the lane file, relative
// to the root, and every changed path outside the lane. Lane artifacts are
// always in lane. Throws on a SCOPE.json it cannot read.
function laneViolations(root, branch) {
  const scopePath = artifactPath(root, 'scope', branch);
  if (!fs.existsSync(scopePath)) return null;
  const scope = JSON.parse(fs.readFileSync(scopePath, 'utf8'));
  const allowedPaths = Array.isArray(scope.allowedPaths) ? scope.allowedPaths : [];
  const forbiddenPaths = Array.isArray(scope.forbiddenPaths) ? scope.forbiddenPaths : [];
  const coordination = coordinationPaths(root, branch);
  const violations = [];
  for (const file of laneChanges(root, branch, scope.baseBranch)) {
    if (coordination.has(file)) continue;
    if (matchesAny(forbiddenPaths, file)) {
      violations.push({ file, why: 'matches forbiddenPaths' });
    } else if (!matchesAny(allowedPaths, file)) {
      violations.push({ file, why: 'not in allowedPaths' });
    }
  }
  return { scope: path.relative(root, scopePath).split(path.sep).join('/'), violations };
}

function laneReport(lane) {
  return lane.violations.map(v => `  ${v.file} (${v.why})`).join('\n');
}
// --- lane matcher: end -------------------------------------------------------

// PostToolUse, Bash: judge the worktree as the call left it.
function afterBash(event) {
  const root = repoRoot(event.cwd);
  const branch = currentBranch(root);
  const lane = laneViolations(root, branch);
  if (!lane || lane.violations.length === 0) process.exit(0);
  const reason =
    `Scope violation after this Bash call: the branch changes files outside the lane in ` +
    `${lane.scope}:\n${laneReport(lane)}\n` +
    `Revert each one now: restore a tracked file from git, delete a new one, and take an ` +
    `out-of-lane file back out of any commit that carries it. If you genuinely need one of ` +
    `these files, revert it anyway, then stop and write BLOCKER.md explaining why. ` +
    `Do not edit SCOPE.json to fit the change.`;
  process.stdout.write(JSON.stringify({ decision: 'block', reason }));
  process.exit(0); // the decision object blocks; exit 2 is not needed
}

let input = '';
process.stdin.setEncoding('utf8');
process.stdin.on('data', c => { input += c; });
process.stdin.on('end', () => {
  try {
    const event = JSON.parse(input);
    if (event.hook_event_name === 'PostToolUse') {
      if (event.tool_name === 'Bash') afterBash(event);
      process.exit(0);
    }

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
