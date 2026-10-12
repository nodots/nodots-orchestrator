#!/usr/bin/env node
'use strict';

/*
 * Stop hook: a worker leaves written state, or it does not leave.
 *
 * On a non-default branch with uncommitted changes and neither HANDOFF.md nor
 * BLOCKER.md present, the turn is blocked from ending, naming both files. This
 * is what makes "the coordinator is not available on demand" survivable: the
 * next session — or the next agent — resumes from a file rather than from a
 * conversation that has been compacted away.
 *
 * Control header
 * --------------
 * Default: block, and only in the one state above. A clean tree, the default
 *   branch, or either file present all allow the stop; the hook is silent
 *   whenever it allows.
 * Fail posture: open, and loud. Any error exits 0 after one stderr line naming
 *   this hook and the error, the same posture as enforce-scope.js. A handoff
 *   convention is a coordination guardrail; a broken sensor must not trap a
 *   session in a turn it cannot end.
 * Residue — what this hook does not judge: whether HANDOFF.md is any good,
 *   whether it describes this work, or whether it is stale. It judges
 *   presence. It also cannot see uncommitted work in another worktree, and it
 *   does not fire when the user interrupts a turn, because Stop does not run
 *   on a user interrupt.
 *
 * Loop safety: `stop_hook_active` is true when the session is already
 * continuing because of a stop hook. This hook allows the stop in that case
 * rather than blocking a second time, so a condition the agent cannot resolve
 * cannot wedge the session. Claude Code independently overrides a Stop hook
 * after 8 consecutive blocks.
 *
 * TaskCompleted (opt-in): the same check, run when a task is being marked
 * complete. It blocks with exit 2 and the reason on stderr, which is how
 * TaskCompleted blocks, and it does not read `stop_hook_active`, which belongs
 * to Stop. The plugin does not register it; wire it by hand from
 * assets/settings-snippet-optional.json.
 *
 * Wire it up in .claude/settings.json:
 *   { "hooks": { "Stop": [ { "hooks": [ { "type": "command",
 *       "command": "node .claude/hooks/require-handoff.js" } ] } ] } }
 */

const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');

const HOOK = 'require-handoff';
const HANDOFF = 'HANDOFF.md';
const BLOCKER = 'BLOCKER.md';
const CELL_DIRS = ['.agentic', '.auto-shop'];
const FALLBACK_DEFAULTS = ['main', 'master', 'development'];

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
    } catch { /* not a repo, or no git on PATH */ }
  }
  return path.resolve(__dirname, '..', '..');
}

// The default branch, from the remote when it is known, and otherwise the
// first conventional name this repo actually has.
function defaultBranch(root) {
  try {
    const ref = git(root, ['symbolic-ref', 'refs/remotes/origin/HEAD']);
    const name = ref.replace(/^refs\/remotes\/origin\//, '');
    if (name) return name;
  } catch { /* no origin, or no HEAD set on it */ }
  for (const name of FALLBACK_DEFAULTS) {
    try {
      git(root, ['rev-parse', '--verify', '--quiet', `refs/heads/${name}`]);
      return name;
    } catch { /* not this one */ }
  }
  return null;
}

function handoffDirs(root, branch) {
  const dirs = [root];
  const parts = branch.split('/').filter(Boolean);
  for (const d of CELL_DIRS) dirs.push(path.join(root, d, 'cells', ...parts));
  return dirs;
}

function hasWrittenState(root, branch) {
  for (const dir of handoffDirs(root, branch)) {
    for (const name of [HANDOFF, BLOCKER]) {
      if (fs.existsSync(path.join(dir, name))) return true;
    }
  }
  return false;
}

let input = '';
process.stdin.setEncoding('utf8');
process.stdin.on('data', c => { input += c; });
process.stdin.on('end', () => {
  try {
    const event = JSON.parse(input);

    const completion = event.hook_event_name === 'TaskCompleted';

    // Already continuing because of a stop hook: never block twice.
    if (!completion && event.stop_hook_active) process.exit(0);

    const root = repoRoot(event.cwd);
    const branch = git(root, ['rev-parse', '--abbrev-ref', 'HEAD']);
    if (!branch || branch === 'HEAD') process.exit(0); // detached: not a worker lane

    const def = defaultBranch(root);
    if (def && branch === def) process.exit(0);        // default branch: not a package

    const dirty = git(root, ['status', '--porcelain']);
    if (!dirty) process.exit(0);                       // nothing uncommitted to describe

    if (hasWrittenState(root, branch)) process.exit(0);

    const reason =
        `This worktree is on ${branch} with uncommitted changes and neither ` +
        `${HANDOFF} nor ${BLOCKER} written. Before ending the turn, write one of them ` +
        `at the repo root or in this branch's cell directory: ${HANDOFF} if the work ` +
        `continues (what is done, what is next, what a cold session needs to resume), ` +
        `${BLOCKER} if it stopped and needs a decision (bucket, kind and reference, ` +
        `alternatives searched, un-block condition, owner, and the one-line ask). ` +
        `Committing or stashing the changes is not the alternative — the point is the ` +
        `written state, not the clean tree.`;

    if (completion) {
      process.stderr.write(reason + '\n');
      process.exit(2); // exit 2 blocks TaskCompleted; stderr is the feedback
    }
    process.stdout.write(JSON.stringify({ decision: 'block', reason }));
    process.exit(0);
  } catch (err) {
    try {
      process.stderr.write(
        `${HOOK}: could not evaluate the handoff state, allowing the stop. ` +
        `${(err && err.message) || err}\n`
      );
    } catch { /* stderr gone; nothing further this hook can do */ }
    process.exit(0);
  }
});
