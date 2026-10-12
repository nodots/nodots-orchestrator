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
 * Default: block, in two states: the one above, and a HANDOFF.md that has no
 *   "Plan check" section (a "Plan check" heading and a line
 *   "Package issue still matches: yes" or "no"). A clean tree, the default
 *   branch, a BLOCKER.md (exempt from the Plan check), or a HANDOFF.md with the
 *   section all allow the stop; the hook is silent whenever it allows.
 * Fail posture: open, and loud. Any error exits 0 after one stderr line naming
 *   this hook and the error, the same posture as enforce-scope.js. A handoff
 *   convention is a coordination guardrail; a broken sensor must not trap a
 *   session in a turn it cannot end.
 * Residue — what this hook does not judge: whether HANDOFF.md is any good,
 *   whether it describes this work, or whether it is stale; whether the Plan
 *   check answer is true, or whether a "no" names the updated issue and what
 *   changed. It judges the presence of the section and of a yes or no. It also
 *   cannot see uncommitted work in another worktree, and it
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
const PLAN_HEADING = /^#{1,6}[ \t]*Plan check[ \t]*$/im;
const PLAN_ANSWER = /^[ \t]*Package issue still matches:[ \t]*(yes|no)[ \t]*$/im;
const PLAN_LINE = 'Package issue still matches: yes';

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

// 'none' when neither file exists, 'blocker' when a BLOCKER.md exists (exempt
// from the Plan check), 'handoff-ok' when a HANDOFF.md carries the Plan check,
// and 'handoff-no-plan-check' when HANDOFF.md exists but none of them does.
function writtenState(root, branch) {
  let handoffSeen = false;
  for (const dir of handoffDirs(root, branch)) {
    if (fs.existsSync(path.join(dir, BLOCKER))) return 'blocker';
    const file = path.join(dir, HANDOFF);
    if (!fs.existsSync(file)) continue;
    handoffSeen = true;
    if (hasPlanCheck(fs.readFileSync(file, 'utf8'))) return 'handoff-ok';
  }
  return handoffSeen ? 'handoff-no-plan-check' : 'none';
}

function hasPlanCheck(text) {
  return PLAN_HEADING.test(text) && PLAN_ANSWER.test(text);
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

    const state = writtenState(root, branch);
    if (state === 'blocker' || state === 'handoff-ok') process.exit(0);

    const reason = state === 'handoff-no-plan-check'
      ? `${HANDOFF} on ${branch} is missing the required "Plan check" section. ` +
        `Add it to ${HANDOFF}, with a line "${PLAN_LINE}" (or "no" when the build ` +
        `diverged from the package issue; then also give the updated issue number ` +
        `and what changed):\n\n## Plan check\n\n${PLAN_LINE}\n`
      : `This worktree is on ${branch} with uncommitted changes and neither ` +
        `${HANDOFF} nor ${BLOCKER} written. Before ending the turn, write one of them ` +
        `at the repo root or in this branch's cell directory: ${HANDOFF} if the work ` +
        `continues (what is done, what is next, what a cold session needs to resume, ` +
        `and a "Plan check" section with the line "${PLAN_LINE}" or "no"), ` +
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
