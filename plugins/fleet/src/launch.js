'use strict';

/*
 * Launching a worker for one package.
 *
 * Local mode: a git worktree on the package branch, the SCOPE.json from the
 * issue committed as "<ID>: scope", a plain push (the claim: a rejected push
 * means someone else owns the branch and this launch stops), then a detached
 * `claude -p` in the worktree. The session record is persisted before the
 * spawn so a crash between the two is visible to the next cycle.
 *
 * Cloud mode is a registered seam that returns "not implemented" until the
 * Phase B spike answers how `claude --cloud` behaves.
 */

const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const { run, spawnDetached, processStart } = require('./exec');
const scope = require('./scope');

const TIERS = ['cheapest', 'default', 'strongest'];

function tierUp(tier) {
  const i = TIERS.indexOf(tier || 'default');
  return TIERS[Math.min(i + 1, TIERS.length - 1)];
}

// **Repo:** `owner/name` on the package header line; a bare name takes the
// host's owner. Same rule as sync-cells.sh.
function declaredRepo(body, hostRepo) {
  const m = /\*\*Repo:\*\*\s*`?([A-Za-z0-9_.\-]+(?:\/[A-Za-z0-9_.\-]+)?)`?/.exec(String(body || ''));
  if (!m) return null;
  return m[1].includes('/') ? m[1] : `${hostRepo.split('/')[0]}/${m[1]}`;
}

function targetFor(cfg, issue) {
  const declared = declaredRepo(issue.body, cfg.repo);
  if (!declared) return cfg.targets[0];
  return cfg.targets.find(t => t.repo === declared) || null;
}

function buildPrompt(cfg, { issue, id, sc, workerId, target, attempt, reason, handoffPresent }) {
  const lines = [
    `You are worker ${workerId} executing work package ${id} (issue #${issue.number} in ${cfg.repo}) in repository ${target.repo}.`,
    `Follow the worker contract at ${cfg.contractPath}, in order. It governs everything below.`,
    `Your lane is .agentic/cells/${sc.branch}/SCOPE.json in this worktree. Execution pattern: ${(sc.execution && sc.execution.pattern) || 'solo'}.`,
    `Read the package with: gh issue view ${issue.number} --repo ${cfg.repo}`,
    `Branch ${sc.branch} is checked out and already pushed. Commit on it. Open the PR against ${target.defaultBranch} with a title starting "[READY]: ${id}" and a body containing "Closes #${issue.number}".`,
    'Do not change any cell:* or worker:* label. Do not edit SCOPE.json. If you need a file outside allowedPaths, stop and write BLOCKER.md.',
  ];
  if (attempt > 1) lines.push(`This is attempt ${attempt}.${handoffPresent ? ' HANDOFF.md is present: read it first, you are resuming.' : ''}${reason ? ` The previous attempt ended with: ${reason}.` : ''}`);
  return lines.join('\n');
}

function buildArgs(cfg, { prompt, tier, sessionId }) {
  const args = ['-p', prompt, '--output-format', 'json',
    '--permission-mode', cfg.permissionMode, '--permission-prompts', cfg.permissionPrompts,
    '--max-budget-usd', String(cfg.maxBudgetUsd), '--session-id', sessionId];
  const model = cfg.models[tier || 'default'];
  if (model) args.push('--model', model);
  return args;
}

function workerEnv({ workerId, issue, id }) {
  const env = { ...process.env };
  delete env.CLAUDECODE;        // a nested-session guard in Claude Code; the worker is its own session
  env.FLEET_WORKER_ID = workerId;
  env.FLEET_ISSUE = String(issue.number);
  env.FLEET_PACKAGE = id;
  return env;
}

// prepareWorktree -> { ok, worktree, headSha, created } | { ok:false, stage, error }
function prepareWorktree(cfg, tracker, { target, id, sc }) {
  const git = cfg.bins.git;
  const worktree = scope.worktreePath(cfg.worktreesDir, target.repo, id);
  const g = (args, cwd) => run(git, ['-C', cwd || target.localPath, ...args], { timeoutMs: 120000 });

  if (!fs.existsSync(target.localPath)) return { ok: false, stage: 'clone', error: `no clone at ${target.localPath}` };

  const f = g(['fetch', 'origin', '--prune']);
  if (f.status !== 0) return { ok: false, stage: 'fetch', error: f.error || f.stderr.trim() };

  const exists = tracker.remoteBranchExists(target.localPath, sc.branch);
  if (!exists.ok) return { ok: false, stage: 'ls-remote', error: exists.error };

  if (fs.existsSync(worktree)) {
    // Adopt only a worktree that is on this branch; anything else is a collision.
    const b = g(['rev-parse', '--abbrev-ref', 'HEAD'], worktree);
    if (b.status !== 0 || b.stdout.trim() !== sc.branch) return { ok: false, stage: 'worktree', error: `${worktree} exists and is not on ${sc.branch}` };
    const h = g(['rev-parse', 'HEAD'], worktree);
    return { ok: true, worktree, headSha: h.stdout.trim(), created: false, remoteExisted: exists.exists };
  }

  if (exists.exists) return { ok: false, stage: 'claim', error: `branch ${sc.branch} already exists on origin and no local worktree holds it; another worker may own it` };

  fs.mkdirSync(cfg.worktreesDir, { recursive: true });
  const w = g(['worktree', 'add', '-b', sc.branch, worktree, `origin/${target.defaultBranch}`]);
  if (w.status !== 0) return { ok: false, stage: 'worktree', error: w.error || w.stderr.trim() };

  const rel = path.join('.agentic', 'cells', ...sc.branch.split('/'), 'SCOPE.json');
  fs.mkdirSync(path.dirname(path.join(worktree, rel)), { recursive: true });
  fs.writeFileSync(path.join(worktree, rel), JSON.stringify(sc, null, 2) + '\n');
  const a = g(['add', '--', rel], worktree);
  if (a.status !== 0) return { ok: false, stage: 'commit', error: a.error || a.stderr.trim() };
  const c = g(['-c', 'user.name=fleet', '-c', 'user.email=fleet@nodots.invalid', 'commit', '-q', '-m', `${id}: scope`], worktree);
  if (c.status !== 0) return { ok: false, stage: 'commit', error: c.error || c.stderr.trim() };

  // Plain push. No --force of any kind: a rejection means the branch appeared
  // between ls-remote and now, and that is someone else's claim.
  const p = g(['push', '-u', 'origin', sc.branch], worktree);
  if (p.status !== 0) return { ok: false, stage: 'push', error: p.error || p.stderr.trim(), worktree };

  const h = g(['rev-parse', 'HEAD'], worktree);
  return { ok: true, worktree, headSha: h.stdout.trim(), created: true, remoteExisted: false };
}

// launch(cfg, tracker, store, req, persist) -> { ok, session } | { ok:false, stage, error }
// req: { issue, id, sc, workerId, attempt, tier, reason, dryRun }
// persist(record) is called with status 'launching' before the spawn and
// 'running' after it, so the state file always leads the process.
function launch(cfg, tracker, store, req, persist) {
  const mode = (req.sc.execution && req.sc.execution.mode) || cfg.workers[req.workerId].mode;
  if (mode === 'cloud') return { ok: false, stage: 'mode', error: 'cloud launch is not implemented (Phase B); set workers.<id>.mode to local or execution.mode to local' };
  if (mode !== 'local') return { ok: false, stage: 'mode', error: `worker ${req.workerId} is ${mode}; the cycle only labels it` };

  const target = targetFor(cfg, req.issue);
  if (!target) return { ok: false, stage: 'target', error: `package names a repo that is not in targets: ${declaredRepo(req.issue.body, cfg.repo)}` };

  if (req.dryRun) {
    return { ok: true, dryRun: true, session: { issue: req.issue.number, id: req.id, branch: req.sc.branch, worktree: scope.worktreePath(cfg.worktreesDir, target.repo, req.id), target: target.repo, tier: req.tier || 'default', mode } };
  }

  const prep = prepareWorktree(cfg, tracker, { target, id: req.id, sc: req.sc });
  if (!prep.ok) return prep;

  const attempt = req.attempt || 1;
  const sessionId = crypto.randomUUID();
  const handoffPresent = fs.existsSync(path.join(prep.worktree, 'HANDOFF.md'))
    || fs.existsSync(path.join(prep.worktree, '.agentic', 'cells', ...req.sc.branch.split('/'), 'HANDOFF.md'));
  const prompt = buildPrompt(cfg, { issue: req.issue, id: req.id, sc: req.sc, workerId: req.workerId, target, attempt, reason: req.reason, handoffPresent });
  const args = buildArgs(cfg, { prompt, tier: req.tier, sessionId });

  const record = {
    issue: req.issue.number, id: req.id, worker: req.workerId, mode, target: target.repo,
    branch: req.sc.branch, worktree: prep.worktree, attempt, tier: req.tier || 'default',
    sessionId, pid: null, procStart: null,
    logPath: store.logPath(req.issue.number, attempt), exitPath: store.exitPath(req.issue.number, attempt),
    startedAt: new Date().toISOString(), launchHeadSha: prep.headSha,
    issueHash: crypto.createHash('sha256').update(`${req.issue.title}\n${req.issue.body || ''}`).digest('hex'),
    status: 'launching', outcome: null, termSentAt: null,
  };
  persist(record);

  const { pid } = spawnDetached(cfg.bins.claude, args, { cwd: prep.worktree, env: workerEnv(req), logPath: record.logPath, exitPath: record.exitPath });
  record.pid = pid;
  record.procStart = processStart(pid);
  record.status = 'running';
  persist(record);
  return { ok: true, session: record, args };
}

module.exports = { launch, prepareWorktree, buildPrompt, buildArgs, workerEnv, declaredRepo, targetFor, tierUp, TIERS };
