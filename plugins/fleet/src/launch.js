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

// The prefix rule for "does this rule apply to the lane": the literal prefix of
// a glob is the text before its first *, ?, [ or {, trailing / trimmed, and two
// globs overlap when one prefix is a string prefix of the other. Deliberately
// coarse: it can name a rule that matches nothing in the lane (packages/webapp
// against packages/web), never omit one that does.
function literalPrefix(glob) {
  const s = String(glob);
  const i = s.search(/[*?[{]/);
  return (i === -1 ? s : s.slice(0, i)).replace(/\/+$/, '');
}
function pathsOverlap(a, b) {
  const pa = literalPrefix(a), pb = literalPrefix(b);
  return pa.startsWith(pb) || pb.startsWith(pa);
}
// A rule with no paths applies everywhere.
function applicableRules(manifest, allowedPaths) {
  const lane = allowedPaths || [];
  return manifest.rules.filter(r => r.paths === null || r.paths.some(p => lane.some(a => pathsOverlap(p, a))));
}

function checkStandardsModule(cfg) {
  return require(path.join(cfg.scriptsDir, 'check-standards.js'));
}

// readBranchStandards -> { ok, manifest } | { ok:false, stage, error }
// The manifest as published on origin/<defaultBranch> of the local clone, with
// the tracked file list of that same tree, validated by check-standards.js.
function readBranchStandards(cfg, target) {
  const ref = `origin/${target.defaultBranch}`;
  const rel = path.posix.normalize(target.standards.manifest);
  const g = args => run(cfg.bins.git, ['-C', target.localPath, ...args], { timeoutMs: 60000 });
  const why = r => r.error || r.stderr.trim() || `exit ${r.status}`;
  const ls = g(['ls-tree', '-r', '-z', '--name-only', ref]);
  if (ls.status !== 0) return { ok: false, stage: 'standards-unreadable', error: `${target.repo}: git ls-tree -r --name-only ${ref} failed in ${target.localPath}, so the standards manifest cannot be read and no worker is launched: ${why(ls)}` };
  const files = ls.stdout.split('\0').filter(Boolean);
  if (!files.includes(rel)) return { ok: false, stage: 'standards-missing', error: `${target.repo} has no ${rel} on ${ref}; publish a standards manifest there, or set targets[].standards to "off" in fleet.config.json` };
  const show = g(['show', `${ref}:${rel}`]);
  if (show.status !== 0) return { ok: false, stage: 'standards-unreadable', error: `${target.repo}: git show ${ref}:${rel} failed in ${target.localPath}: ${why(show)}` };
  const v = checkStandardsModule(cfg).validateStandards({ text: show.stdout, files });
  if (!v.ok) return { ok: false, stage: 'standards-invalid', error: `${target.repo}: ${rel} on ${ref} is not a valid standards manifest, so no worker is launched: ${v.defects.join('; ')}` };
  return { ok: true, manifest: v.manifest };
}

// The worktree's copy, read after prepareWorktree and validated again. A copy
// that differs from the one read on the default branch (it changed between the
// two reads, or an adopted branch carries another) is refused standards-invalid:
// the prompt must describe the manifest the dry run reported.
function readWorktreeStandards(cfg, target, worktree, expected) {
  const rel = path.posix.normalize(target.standards.manifest);
  const refuse = msg => ({ ok: false, stage: 'standards-invalid', error: `${target.repo}: ${rel} in ${worktree} ${msg}` });
  let text;
  try { text = fs.readFileSync(path.join(worktree, rel), 'utf8'); } catch (e) { return refuse(`cannot be read (${e.code || e.message}), so it differs from origin/${target.defaultBranch}`); }
  const ls = run(cfg.bins.git, ['-C', worktree, 'ls-files', '-z'], { timeoutMs: 60000 });
  if (ls.status !== 0) return refuse(`cannot be validated: git ls-files failed: ${ls.error || ls.stderr.trim()}`);
  const v = checkStandardsModule(cfg).validateStandards({ text, files: ls.stdout.split('\0').filter(Boolean) });
  if (!v.ok) return refuse(`is not a valid standards manifest: ${v.defects.join('; ')}`);
  if (JSON.stringify(v.manifest) !== JSON.stringify(expected)) return refuse(`differs from the one on origin/${target.defaultBranch} read before the worktree was prepared`);
  return { ok: true, manifest: v.manifest };
}

function standardsRecord(manifest, sc) {
  if (!manifest) return 'off';
  return { checks: manifest.checks.map(c => c.name), rules: manifest.rules.length, applicable: applicableRules(manifest, sc.allowedPaths).length };
}

function standardsLines(target, title, sc, manifest) {
  const rel = target.standards.manifest;
  const lines = [`Standards for ${target.repo} are in ${rel} in this worktree. Before you claim ${title}, run every check in order and quote each command with its summary in the VERIFIED stamp: ${manifest.checks.map(c => `${c.name}: ${c.command}`).join('; ')}`];
  const rules = applicableRules(manifest, sc.allowedPaths);
  lines.push(rules.length
    ? `Rules for your lane; read each doc before changing code under its paths: ${rules.map(r => `${r.doc} (${r.paths ? r.paths.join(', ') : 'all paths'})`).join('; ')}`
    : `No rule in ${rel} names paths in your lane; the checks still apply.`);
  if (manifest.plugins.length) lines.push(`This repo's standards expect ${manifest.plugins.map(p => `${p.name}@${p.marketplace}`).join(', ')}; if a skill or hook from it is absent in this session, say so in HANDOFF.md.`);
  return lines;
}

// A target with verify (config.js) admits one verifier run at a time, so the
// worker stops at a "[VERIFY]:" PR the queue picks up. These lines replace the
// contract's "[READY]:" title and VERIFIED stamp; "[READY]" is never said.
// The worker cannot read outside its worktree, so the in-repo contract wins
// when the worktree has one; the plugin's copy is named only when it does not.
// standards: the worktree's validated manifest ({ manifest }); launch() passes
// it whenever the target's standards is not "off", and refuses the launch when
// it cannot. Absent, the prompt carries no standards lines.
function buildPrompt(cfg, { issue, id, sc, workerId, target, attempt, reason, handoffPresent, worktree, standards }) {
  const queued = Boolean(target.verify);
  const title = queued ? `[VERIFY]: ${id}` : `[READY]: ${id}`;
  const inRepo = Boolean(worktree) && fs.existsSync(path.join(worktree, '.claude', 'worker-contract.md'));
  const lines = [
    `You are worker ${workerId} executing work package ${id} (issue #${issue.number} in ${cfg.repo}) in repository ${target.repo}.`,
    `Follow the worker contract at ${inRepo ? '.claude/worker-contract.md in this worktree' : cfg.contractPath}, in order. It governs everything below.`,
    `Your lane is .agentic/cells/${sc.branch}/SCOPE.json in this worktree. Execution pattern: ${(sc.execution && sc.execution.pattern) || 'solo'}.`,
    ...(standards ? standardsLines(target, title, sc, standards.manifest) : []),
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

  // A target without a valid standards manifest is refused like one without
  // CI: before any worktree, branch or worker exists.
  const standardsOff = target.standards === 'off';
  let branchStandards = null;
  if (!standardsOff) {
    const s = readBranchStandards(cfg, target);
    if (!s.ok) return s;
    branchStandards = s.manifest;
  }
  const standards = standardsRecord(branchStandards, req.sc);

  if (req.dryRun) {
    return { ok: true, dryRun: true, session: { issue: req.issue.number, id: req.id, branch: req.sc.branch, worktree: scope.worktreePath(cfg.worktreesDir, target.repo, req.id), target: target.repo, tier: req.tier || 'default', mode, ci: ciRecord, standards } };
  }

  const prep = prepareWorktree(cfg, tracker, { target, id: req.id, sc: req.sc });
  if (!prep.ok) return prep;

  // The worktree now exists and its branch is pushed; a refusal here leaves
  // them for the next cycle to adopt, and starts no worker.
  let worktreeStandards = null;
  if (!standardsOff) {
    const s = readWorktreeStandards(cfg, target, prep.worktree, branchStandards);
    if (!s.ok) return s;
    worktreeStandards = { manifest: s.manifest };
  }

  const attempt = req.attempt || 1;
  const sessionId = crypto.randomUUID();
  const handoffPresent = fs.existsSync(path.join(prep.worktree, 'HANDOFF.md'))
    || fs.existsSync(path.join(prep.worktree, '.agentic', 'cells', ...req.sc.branch.split('/'), 'HANDOFF.md'));
  const prompt = buildPrompt(cfg, { issue: req.issue, id: req.id, sc: req.sc, workerId: req.workerId, target, attempt, reason: req.reason, handoffPresent, worktree: prep.worktree, standards: worktreeStandards });
  const args = buildArgs(cfg, { prompt, tier: req.tier, sessionId });

  const record = {
    issue: req.issue.number, id: req.id, worker: req.workerId, mode, target: target.repo,
    branch: req.sc.branch, worktree: prep.worktree, attempt, tier: req.tier || 'default',
    sessionId, pid: null, procStart: null, ci: ciRecord, standards,
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

module.exports = { localWorktreeOnBranch, launch, prepareWorktree, buildPrompt, buildArgs, workerEnv, declaredRepo, targetFor, tierUp, TIERS, pathsOverlap, applicableRules };
