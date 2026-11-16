#!/usr/bin/env node
'use strict';

/*
 * Stop hook: a worker leaves written state, or it does not leave.
 *
 * On a branch that is neither the default nor develop, with uncommitted changes and neither HANDOFF.md nor
 * BLOCKER.md present, the turn is blocked from ending, naming both files. This
 * is what makes "the coordinator is not available on demand" survivable: the
 * next session — or the next agent — resumes from a file rather than from a
 * conversation that has been compacted away.
 *
 * Lane check: when a SCOPE.json governs the branch, the stop first runs the
 * same lane check as enforce-scope.js's PostToolUse Bash mode, over the
 * branch's whole change against its merge base with the nearest integration
 * branch — committed, staged, unstaged and untracked. An out-of-lane path
 * blocks the stop and is named, whatever HANDOFF.md or BLOCKER.md says, and on
 * a clean tree too. Lane artifacts (SCOPE.json, HANDOFF.md, BLOCKER.md) are
 * always in lane. No SCOPE.json => no lane check.
 *
 * Control header
 * --------------
 * Default: block, in three states: an out-of-lane change, the one above, and a
 *   HANDOFF.md that has no "Plan check" section (a "Plan check" heading and a
 *   line "Package issue still matches: yes" or "no"). Otherwise a clean tree,
 *   the default branch, develop, a BLOCKER.md (exempt from the Plan check), or
 *   a HANDOFF.md with the section all allow the stop; the hook is silent
 *   whenever it allows.
 * Fail posture: open, and loud. Any error exits 0 after one stderr line naming
 *   this hook and the error, the same posture as enforce-scope.js. A lane it
 *   cannot evaluate is reported the same way and skipped, and the handoff
 *   check still runs. A handoff convention is a coordination guardrail; a
 *   broken sensor must not trap a session in a turn it cannot end.
 * Residue — what this hook does not judge: whether HANDOFF.md is any good,
 *   whether it describes this work, or whether it is stale; whether the Plan
 *   check answer is true, or whether a "no" names the updated issue and what
 *   changed. It judges the presence of the section and of a yes or no. It also
 *   cannot see uncommitted work in another worktree, and it
 *   does not fire when the user interrupts a turn, because Stop does not run
 *   on a user interrupt. What the lane check still does not catch: writes
 *   outside the worktree; a change made and reverted within one Bash call (or
 *   by MCP filesystem tools between Bash calls), because it judges only what is
 *   still present at the stop; a gitignored path; commits, when the repo has no
 *   integration branch to take a merge base from; and an out-of-lane change
 *   the worker leaves in place after the first block, because the loop guard
 *   allows the second stop.
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
const FALLBACK_DEFAULTS = ['main', 'master', 'development'];
// An integration branch that is not the remote's default (master is the
// default, develop takes the merges): not a package lane either.
const INTEGRATION_BRANCHES = ['develop'];
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

// The merge base with the nearest integration branch: of origin/HEAD and the
// LANE_BASES names, local or on origin, the one HEAD is fewest commits ahead
// of. Nearest rather than the remote default, because a default that lags the
// integration branch would count every package merged since as this branch's
// change. null when there is no other branch to measure from.
function laneMergeBase(root, branch) {
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
function laneChanges(root, branch) {
  const files = new Set();
  const status = laneGit(root, ['status', '--porcelain', '-z', '--untracked-files=all', '--no-renames']);
  for (const entry of status.split('\0')) {
    if (entry.length > 3) files.add(entry.slice(3)); // "XY <path>"
  }
  const base = laneMergeBase(root, branch);
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
  for (const file of laneChanges(root, branch)) {
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

// The lane check, or null when there is no lane to check. A lane it cannot
// evaluate is reported loudly and skipped, so a broken SCOPE.json does not also
// switch off the handoff check below.
function laneCheck(root, branch) {
  try {
    return laneViolations(root, branch);
  } catch (err) {
    process.stderr.write(
      `${HOOK}: could not evaluate the scope lane, skipping the lane check. ` +
      `${(err && err.message) || err}\n`
    );
    return null;
  }
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
    if (INTEGRATION_BRANCHES.includes(branch)) process.exit(0); // integration branch: not a package

    const block = reason => {
      if (completion) {
        process.stderr.write(reason + '\n');
        process.exit(2); // exit 2 blocks TaskCompleted; stderr is the feedback
      }
      process.stdout.write(JSON.stringify({ decision: 'block', reason }));
      process.exit(0);
    };

    // The lane first, and on a clean tree too: a committed change counts.
    const lane = laneCheck(root, branch);
    if (lane && lane.violations.length > 0) {
      block(
        `This branch, ${branch}, changes files outside the lane in ${lane.scope} ` +
        `(committed, staged, unstaged or untracked):\n${laneReport(lane)}\n` +
        `Revert each one before ending the turn: restore a tracked file from git, delete a ` +
        `new one, and take an out-of-lane file back out of any commit that carries it. ` +
        `If the work cannot be done without them, revert them anyway and write ${BLOCKER}; ` +
        `a ${BLOCKER} does not excuse a change left outside the lane. ` +
        `Do not edit SCOPE.json to fit the change.`
      );
    }

    const dirty = git(root, ['status', '--porcelain']);
    if (!dirty) process.exit(0);                       // nothing uncommitted to describe

    const state = writtenState(root, branch);
    if (state === 'blocker' || state === 'handoff-ok') process.exit(0);

    block(state === 'handoff-no-plan-check'
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
        `written state, not the clean tree.`);
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
