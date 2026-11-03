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
const trust = require('./trust');

const TIERS = ['cheapest', 'default', 'strongest'];

// FLEET_CRASH_AT=<stage> kills the process at a chosen point so the fixture
// tests can prove recovery. Honored only with FLEET_TEST_HOOKS=1, so a stray
// variable in a real environment cannot stop a launch.
function crashPoint(stage) {
  if (process.env.FLEET_TEST_HOOKS === '1' && process.env.FLEET_CRASH_AT === stage) {
    process.stderr.write(`fleet: FLEET_CRASH_AT=${stage}, exiting\n`);
    process.exit(70);
  }
}

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

// A target with verify (config.js) admits one verifier run at a time, so the
// worker stops at a "[VERIFY]:" PR the queue picks up. These lines replace the
// contract's "[READY]:" title and VERIFIED stamp; "[READY]" is never said.
// The worker cannot read outside its worktree, so the in-repo contract wins
// when the worktree has one; the plugin's copy is named only when it does not.
function buildPrompt(cfg, { issue, id, sc, workerId, target, attempt, reason, handoffPresent, worktree }) {
  const queued = Boolean(target.verify);
  const title = queued ? `[VERIFY]: ${id}` : `[READY]: ${id}`;
  const inRepo = Boolean(worktree) && fs.existsSync(path.join(worktree, '.claude', 'worker-contract.md'));
  const lines = [
    `You are worker ${workerId} executing work package ${id} (issue #${issue.number} in ${cfg.repo}) in repository ${target.repo}.`,
    `Follow the worker contract at ${inRepo ? '.claude/worker-contract.md in this worktree' : cfg.contractPath}, in order. It governs everything below.`,
    `Your lane is .agentic/cells/${sc.branch}/SCOPE.json in this worktree. Execution pattern: ${(sc.execution && sc.execution.pattern) || 'solo'}.`,
    `Read the package with: gh issue view ${issue.number} --repo ${cfg.repo}`,
    `Branch ${sc.branch} is checked out and already pushed. Commit on it. Open the PR against ${target.defaultBranch} with a title starting "${title}" and a body containing "Closes #${issue.number}".`,
    'Do not change any cell:* or worker:* label. Do not edit SCOPE.json. If you need a file outside allowedPaths, stop and write BLOCKER.md.',
  ];
  if (queued) {
    lines.push(
      `${target.repo} is verified through a queue that admits one run at a time (${target.verify.kind}, suite ${target.verify.suite}). For this target the PR title above and the steps below replace the contract's completion title and its VERIFIED stamp.`,
      'Do not run the verifier, and do not claim any lock it uses. Do not post a VERIFIED stamp: the queue runs the verifier and stamps the PR.',
      `In the PR body, paste the selection this target's tooling lists for your change. How to list it: ${target.ci.verifiedBy}.`,
    );
  } else if (target.ci && target.ci.gate === 'external') {
    lines.push(`No GitHub Actions workflow verifies ${target.repo}. Verification for this target: ${target.ci.verifiedBy}. Your VERIFIED stamp must come from that run, not from a pipeline.`);
  }
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
    // The issue is the source of truth for the lane. If the coordinator re-cut
    // it (a parked package whose lane was wrong), the committed copy follows,
    // as its own commit, so the hook enforces the lane that was decided.
    const rel = path.join('.agentic', 'cells', ...sc.branch.split('/'), 'SCOPE.json');
    const want = JSON.stringify(sc, null, 2) + '\n';
    let have = null; try { have = fs.readFileSync(path.join(worktree, rel), 'utf8'); } catch { /* absent */ }
    const recut = have !== want;
    if (recut) {
      fs.mkdirSync(path.dirname(path.join(worktree, rel)), { recursive: true });
      fs.writeFileSync(path.join(worktree, rel), want);
    }
    // A lane on disk is not a claim. A launch that died before its commit (an
    // ignored .agentic/, say) left the file untracked, so commit it here: a
    // never-committed lane as "<ID>: scope", like a new worktree's, and a lane
    // that changed against HEAD as a re-cut. Only the lane is committed.
    const tracked = g(['ls-files', '--error-unmatch', '--', rel], worktree).status === 0;
    if (!tracked || g(['diff', '--quiet', 'HEAD', '--', rel], worktree).status !== 0) {
      const a = g(['add', '--', rel], worktree);
      if (a.status !== 0) return { ok: false, stage: 'commit', error: a.error || a.stderr.trim() };
      const c = g(['-c', 'user.name=fleet', '-c', 'user.email=fleet@nodots.invalid', 'commit', '-q', '-m', tracked ? `${id}: scope re-cut` : `${id}: scope`, '--', rel], worktree);
      if (c.status !== 0) return { ok: false, stage: tracked ? 'recut' : 'commit', error: c.error || c.stderr.trim() };
    }
    // Push when the branch does not track its own remote branch, or is ahead
    // of it. Plain push, never forced: a rejection is someone else's claim.
    const u = g(['rev-parse', '--abbrev-ref', '--symbolic-full-name', '@{u}'], worktree);
    const ownUpstream = u.status === 0 && u.stdout.trim() === `origin/${sc.branch}`;
    const ahead = ownUpstream ? g(['rev-list', '--count', '@{u}..HEAD'], worktree) : null;
    if (ahead && ahead.status !== 0) return { ok: false, stage: 'worktree', error: ahead.error || ahead.stderr.trim() };
    if (!ownUpstream || Number(ahead.stdout.trim()) > 0) {
      const p = g(['push', '-u', 'origin', sc.branch], worktree);
      if (p.status !== 0) return { ok: false, stage: 'claim', error: `push of adopted ${sc.branch} was rejected; another worker may own it: ${p.error || p.stderr.trim()}`, worktree };
    }
    const h = g(['rev-parse', 'HEAD'], worktree);
    return { ok: true, worktree, headSha: h.stdout.trim(), created: false, adopted: true, recut, remoteExisted: exists.exists };
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

  crashPoint('after-push');
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

  const t = trust.isTrusted(cfg.bins.git, target.localPath);
  if (!t.trusted) return { ok: false, stage: 'trust', error: `${target.localPath} is not a trusted workspace, so the worker's permissions.allow rules would be ignored under -p and it could not commit, push or open a PR; ${trust.howToTrust(t)}${t.error ? ` (${t.error})` : ''}` };

  // Unattended edits are only as safe as the CI that catches them. Blast
  // radius is not measured here; see references/scope-contract.md.
  // A target declared ci.gate "external" is verified elsewhere; its verifiedBy
  // goes to the worker and onto the session record instead of this check.
  const ciGate = (target.ci && target.ci.gate) || 'github-actions';
  if (ciGate === 'github-actions') {
    const ci = tracker.ciStatus(target.repo, target.defaultBranch);
    if (!ci.ok) return { ok: false, stage: 'ci-check-failed', error: `cannot read CI state for ${target.repo}, so no worker is launched: ${ci.error}` };
    if (ci.enabledWorkflows === 0) return { ok: false, stage: 'ci-disabled', error: `${target.repo} has no enabled CI workflow; enable one before unattended workers run there` };
    const ageDays = ci.lastRunAt ? (Date.now() - Date.parse(ci.lastRunAt)) / 86400000 : Infinity;
    if (!(ageDays <= cfg.ciMaxAgeDays)) return { ok: false, stage: 'ci-stale', error: `${target.repo}: ${ci.lastRunAt ? `the last workflow run on ${target.defaultBranch} was ${ci.lastRunAt}` : `no workflow run on ${target.defaultBranch}`}, outside the ${cfg.ciMaxAgeDays}-day window (ciMaxAgeDays)` };
  }
  const ciRecord = ciGate === 'external' ? { gate: 'external', verifiedBy: target.ci.verifiedBy } : { gate: 'github-actions' };

  if (req.dryRun) {
    return { ok: true, dryRun: true, session: { issue: req.issue.number, id: req.id, branch: req.sc.branch, worktree: scope.worktreePath(cfg.worktreesDir, target.repo, req.id), target: target.repo, tier: req.tier || 'default', mode, ci: ciRecord } };
  }

  const prep = prepareWorktree(cfg, tracker, { target, id: req.id, sc: req.sc });
  if (!prep.ok) return prep;

  const attempt = req.attempt || 1;
  const sessionId = crypto.randomUUID();
  const handoffPresent = fs.existsSync(path.join(prep.worktree, 'HANDOFF.md'))
    || fs.existsSync(path.join(prep.worktree, '.agentic', 'cells', ...req.sc.branch.split('/'), 'HANDOFF.md'));
  const prompt = buildPrompt(cfg, { issue: req.issue, id: req.id, sc: req.sc, workerId: req.workerId, target, attempt, reason: req.reason, handoffPresent, worktree: prep.worktree });
  const args = buildArgs(cfg, { prompt, tier: req.tier, sessionId });

  const record = {
    issue: req.issue.number, id: req.id, worker: req.workerId, mode, target: target.repo,
    branch: req.sc.branch, worktree: prep.worktree, attempt, tier: req.tier || 'default',
    sessionId, pid: null, procStart: null, ci: ciRecord,
    logPath: store.logPath(req.issue.number, attempt), exitPath: store.exitPath(req.issue.number, attempt),
    startedAt: new Date().toISOString(), launchHeadSha: prep.headSha,
    issueHash: crypto.createHash('sha256').update(`${req.issue.title}\n${req.issue.body || ''}`).digest('hex'),
    status: 'launching', outcome: null, termSentAt: null,
  };
  persist(record);
  crashPoint('after-persist');

  const { pid } = spawnDetached(cfg.bins.claude, args, { cwd: prep.worktree, env: workerEnv(req), logPath: record.logPath, exitPath: record.exitPath });
  record.pid = pid;
  record.procStart = processStart(pid);
  record.status = 'running';
  persist(record);
  record.adopted = Boolean(prep.adopted);
  record.recut = Boolean(prep.recut);
  return { ok: true, session: record, args, adopted: Boolean(prep.adopted), recut: Boolean(prep.recut) };
}

// A worktree this machine already holds on the package branch: a launch that
// crashed between its push and its record left one behind, and it is ours to adopt.
function localWorktreeOnBranch(cfg, target, id, branch) {
  const wt = scope.worktreePath(cfg.worktreesDir, target.repo, id);
  if (!fs.existsSync(wt)) return null;
  const r = run(cfg.bins.git, ['-C', wt, 'rev-parse', '--abbrev-ref', 'HEAD'], { timeoutMs: 15000 });
  return r.status === 0 && r.stdout.trim() === branch ? wt : null;
}

module.exports = { localWorktreeOnBranch, launch, prepareWorktree, buildPrompt, buildArgs, workerEnv, declaredRepo, targetFor, tierUp, TIERS };
