'use strict';

/*
 * fleet.config.json: loaded once per command, validated, defaults filled.
 *
 * Nothing here is tracker state. The file names the program (host repo and
 * epic), the target repos and their local clones, the worker ids and how each
 * one runs, and the knobs the cycle needs. Binaries are resolved from GH_BIN,
 * GIT_BIN and CLAUDE_BIN so the fixture tests can stub them, the same seam the
 * plugin scripts use.
 */

const fs = require('fs');
const path = require('path');

const MODES = new Set(['local', 'cloud', 'external']);
const PERMISSION_MODES = new Set(['acceptEdits', 'auto', 'dontAsk', 'default', 'plan', 'bypassPermissions']);
const APPROVAL_MODES = new Set(['off', 'branch-protection', 'ruleset']);
const CI_GATES = new Set(['github-actions', 'external']);
const WORKER_ID = /^[A-Za-z0-9_-]+$/;
const VERIFY_KINDS = new Set(['lab-runner', 'manual']);
const SUITE_ID = /^[A-Za-z0-9_-]+$/;

const DEFAULTS = {
  wipCap: 4,
  permissionMode: 'acceptEdits',
  permissionPrompts: 'none',
  maxBudgetUsd: 25,
  sessionTimeoutMinutes: 120,
  killGraceSeconds: 60,
  maxEscalations: 2,
  noMovementLimit: 3,
  maxCycleMinutes: 30,
  externalStartTimeoutMinutes: 240,
  ciMaxAgeDays: 14,
  approvalEnforcement: 'off',
  // isolateWorkers: workers run under --setting-sources project,local, so the
  // operator's user settings, user-enabled plugins and user instruction file do
  // not reach a target repo. The spike on #128 found a plugin enabled only in
  // user settings does not load then, so its hooks do not run; a plugin enabled
  // in the repo's .claude/settings.json, or hooks wired there by path, do. Launch
  // refuses a target that provides neither (hooks-missing, plugin-missing).
  isolateWorkers: true,
  models: { cheapest: 'haiku', default: null, strongest: 'opus' },
};

function fail(msg) {
  const e = new Error(`fleet config: ${msg}`);
  e.code = 'ECONFIG';
  throw e;
}

// The two plugins ship side by side, in two layouts:
//   repo:      <root>/plugins/fleet/src  ->  <root>/plugins/agentic-work-packages
//   installed: <cache>/<marketplace>/fleet/<ver>/src -> <cache>/<marketplace>/agentic-work-packages/<highest ver>
// A directory counts only when it holds .claude-plugin/plugin.json.
function isPlugin(dir) { return fs.existsSync(path.join(dir, '.claude-plugin', 'plugin.json')); }
function highestVersionDir(parent) {
  let dirs = [];
  try { dirs = fs.readdirSync(parent).filter(d => /^\d+\.\d+\.\d+/.test(d) && isPlugin(path.join(parent, d))); } catch { return null; }
  dirs.sort((a, b) => { const pa = a.split(/[.-]/).map(Number), pb = b.split(/[.-]/).map(Number); for (let i = 0; i < 3; i++) if (pa[i] !== pb[i]) return (pb[i] || 0) - (pa[i] || 0); return 0; });
  return dirs.length ? path.join(parent, dirs[0]) : null;
}
function defaultPluginRoot(fromDir = __dirname) {
  const sibling = path.resolve(fromDir, '..', '..', 'agentic-work-packages');
  if (isPlugin(sibling)) return sibling;
  const installed = path.resolve(fromDir, '..', '..', '..', 'agentic-work-packages');
  return highestVersionDir(installed);
}

function loadConfig(file) {
  const abs = path.resolve(file);
  if (!fs.existsSync(abs)) fail(`no such file: ${abs}`);
  let raw;
  try { raw = JSON.parse(fs.readFileSync(abs, 'utf8')); }
  catch (e) { fail(`${abs} is not valid JSON: ${e.message}`); }
  return validate(raw, path.dirname(abs));
}

// verify: a target whose verifier admits one run at a time. A worker there does
// not run the verifier; it stops at a "[VERIFY]:" PR the queue picks up. The
// verifier is reached on loopback only, and the suite id goes into a request,
// so both are checked here rather than trusted. ci.gate must be external: a
// target verified by GitHub Actions has no queue to hand the PR to.
// kind "manual": the verifier is a person or a script outside fleet. fleet
// makes no request, so a url is refused rather than ignored. suite is optional;
// the worker prompt (launch.js) names it, and prints "undefined" without it.
function isLoopback(hostname) {
  const h = hostname.replace(/^\[|\]$/g, '').toLowerCase();
  return h === 'localhost' || h === '::1' || /^127(\.\d{1,3}){3}$/.test(h);
}
function validateVerify(v, ci, i) {
  const at = `targets[${i}].verify`;
  if (!v || typeof v !== 'object' || Array.isArray(v)) fail(`${at} must be an object {kind, url, suite}`);
  if (!VERIFY_KINDS.has(v.kind)) fail(`${at}.kind [${v.kind}] must be one of ${[...VERIFY_KINDS].join(', ')}`);
  if (v.kind === 'manual') {
    if (ci.gate !== 'external') fail(`${at} requires targets[${i}].ci.gate external: a target with a verify queue is not verified by GitHub Actions`);
    if (v.url !== undefined) fail(`${at}.url is not used by kind manual: fleet makes no request to a manual verifier; remove it`);
    if (v.suite !== undefined && (typeof v.suite !== 'string' || !SUITE_ID.test(v.suite))) fail(`${at}.suite [${v.suite}] must match ${SUITE_ID}`);
    return v.suite === undefined ? { kind: 'manual' } : { kind: 'manual', suite: v.suite };
  }
  let u;
  try { u = new URL(String(v.url)); } catch { fail(`${at}.url [${v.url}] is not a URL`); }
  if (u.protocol !== 'http:' && u.protocol !== 'https:') fail(`${at}.url must be http or https`);
  if (!isLoopback(u.hostname)) fail(`${at}.url host [${u.hostname}] must be loopback (127.0.0.0/8, localhost or ::1)`);
  if (typeof v.suite !== 'string' || !SUITE_ID.test(v.suite)) fail(`${at}.suite [${v.suite}] must match ${SUITE_ID}`);
  if (ci.gate !== 'external') fail(`${at} requires targets[${i}].ci.gate external: a target with a verify queue is not verified by GitHub Actions`);
  return { kind: v.kind, url: v.url, suite: v.suite };
}

// standards: where the target publishes its standards manifest. Launch reads it
// from the default branch and refuses a target without a valid one (launch.js).
// The string "off" launches without one, and the dry run and report say so.
const DEFAULT_STANDARDS_MANIFEST = '.claude/standards.json';
function validateStandardsField(s, i) {
  const at = `targets[${i}].standards`;
  if (s === undefined) return { manifest: DEFAULT_STANDARDS_MANIFEST };
  if (s === 'off') return 'off';
  if (!s || typeof s !== 'object' || Array.isArray(s)) fail(`${at} must be {"manifest": "<relative path>"} or "off"`);
  const m = s.manifest;
  if (typeof m !== 'string' || !m) fail(`${at}.manifest must be a non-empty relative path`);
  if (path.isAbsolute(m) || m.startsWith('/')) fail(`${at}.manifest [${m}] must be relative to the target repo root`);
  if (m.split(/[\\/]/).includes('..')) fail(`${at}.manifest [${m}] must not contain a ".." segment`);
  return { manifest: m };
}

function validate(raw, baseDir) {
  const c = { ...DEFAULTS, ...raw, models: { ...DEFAULTS.models, ...(raw.models || {}) } };

  if (typeof c.repo !== 'string' || !/^[\w.-]+\/[\w.-]+$/.test(c.repo)) fail('repo must be "owner/name"');
  if (!Number.isInteger(c.epic) || c.epic <= 0) fail('epic must be a positive issue number');

  if (!Array.isArray(c.targets) || c.targets.length === 0) fail('targets must list at least one {repo, localPath, defaultBranch}');
  c.targets = c.targets.map((t, i) => {
    if (!t || typeof t.repo !== 'string') fail(`targets[${i}].repo is required`);
    if (typeof t.localPath !== 'string') fail(`targets[${i}].localPath is required`);
    // ci: where this target's changes are verified. "github-actions" (the default) makes launch
    // require an enabled workflow and a recent run on defaultBranch. "external" is for a target
    // whose verification runs outside GitHub Actions (another CI, a lab, a device farm); launch
    // then skips that check, and verifiedBy has to say what verifies the work instead, because
    // the worker is told it and the dry run reports it. It is never silent.
    const ci = t.ci === undefined ? { gate: 'github-actions' } : t.ci;
    if (!ci || typeof ci !== 'object' || !CI_GATES.has(ci.gate)) fail(`targets[${i}].ci.gate must be one of ${[...CI_GATES].join(', ')}`);
    if (ci.gate === 'external' && (typeof ci.verifiedBy !== 'string' || !ci.verifiedBy.trim())) {
      fail(`targets[${i}].ci.verifiedBy is required when ci.gate is external: name what verifies this target's changes`);
    }
    const target = {
      repo: t.repo.includes('/') ? t.repo : `${c.repo.split('/')[0]}/${t.repo}`,
      localPath: path.resolve(baseDir, t.localPath),
      defaultBranch: t.defaultBranch || 'main',
      ci: ci.gate === 'external' ? { gate: 'external', verifiedBy: ci.verifiedBy.trim() } : { gate: 'github-actions' },
    };
    if (t.verify !== undefined) target.verify = validateVerify(t.verify, ci, i);
    target.standards = validateStandardsField(t.standards, i);
    return target;
  });

  if (!c.workers || typeof c.workers !== 'object' || Object.keys(c.workers).length === 0) fail('workers must map at least one id to {mode}');
  for (const [id, w] of Object.entries(c.workers)) {
    if (!WORKER_ID.test(id)) fail(`worker id [${id}] may use letters, digits, _ and - only`);
    if (!w || !MODES.has(w.mode)) fail(`workers.${id}.mode must be one of local, cloud, external`);
  }

  for (const k of ['wipCap', 'sessionTimeoutMinutes', 'killGraceSeconds', 'maxEscalations', 'noMovementLimit', 'maxCycleMinutes', 'externalStartTimeoutMinutes']) {
    if (!Number.isInteger(c[k]) || c[k] < 0 || (k === 'wipCap' && c[k] === 0)) fail(`${k} must be a non-negative integer${k === 'wipCap' ? ' above zero' : ''}`);
  }
  if (!Number.isInteger(c.ciMaxAgeDays) || c.ciMaxAgeDays <= 0) fail('ciMaxAgeDays must be a positive integer');
  if (!APPROVAL_MODES.has(c.approvalEnforcement)) fail(`approvalEnforcement [${c.approvalEnforcement}] must be one of ${[...APPROVAL_MODES].join(', ')}`);
  if (typeof c.maxBudgetUsd !== 'number' || c.maxBudgetUsd <= 0) fail('maxBudgetUsd must be a positive number');
  if (!PERMISSION_MODES.has(c.permissionMode)) fail(`permissionMode [${c.permissionMode}] is not a Claude Code permission mode`);
  if (c.permissionPrompts !== 'none' && c.permissionPrompts !== 'host') fail('permissionPrompts must be "none" or "host"');
  if (typeof c.isolateWorkers !== 'boolean') fail(`isolateWorkers [${c.isolateWorkers}] must be true or false`);

  const first = c.targets[0];
  const repoName = first.repo.split('/')[1];
  c.worktreesDir = path.resolve(baseDir, c.worktreesDir || path.join(path.dirname(first.localPath), `${repoName}-worktrees`));
  c.stateDir = path.resolve(baseDir, c.stateDir || path.join(c.worktreesDir, '.fleet'));
  c.pluginRoot = c.pluginRoot ? path.resolve(baseDir, c.pluginRoot) : defaultPluginRoot();
  if (!c.pluginRoot) fail('pluginRoot is required: the path to the installed agentic-work-packages plugin');
  c.skillRoot = path.join(c.pluginRoot, 'skills', 'agentic-work-packages');
  c.scriptsDir = path.join(c.skillRoot, 'assets', 'scripts');
  c.contractPath = path.join(c.skillRoot, 'assets', 'worker-contract.md');

  c.bins = {
    gh: process.env.GH_BIN || (c.bins && c.bins.gh) || 'gh',
    git: process.env.GIT_BIN || (c.bins && c.bins.git) || 'git',
    claude: process.env.CLAUDE_BIN || (c.bins && c.bins.claude) || 'claude',
  };

  c.workerIds = Object.keys(c.workers);
  c.ownedIds = c.workerIds.filter(id => c.workers[id].mode !== 'external');
  return c;
}

// Approval enforcement (decision D1): off by default. When off, nothing here
// blocks a merge. When on, the host forge enforces the rule; GitHub applies
// the payload below through the mechanism the plan supports.
const REVIEW_COUNT = 1;

function approvalPayload(c) {
  if (c.approvalEnforcement === 'branch-protection') {
    // PUT /repos/{owner}/{repo}/branches/{branch}/protection
    return { required_status_checks: null, enforce_admins: null, required_pull_request_reviews: { required_approving_review_count: REVIEW_COUNT }, restrictions: null };
  }
  if (c.approvalEnforcement === 'ruleset') {
    // POST /repos/{owner}/{repo}/rulesets
    return {
      name: 'require-human-approval', target: 'branch', enforcement: 'active',
      conditions: { ref_name: { include: ['~DEFAULT_BRANCH'], exclude: [] } },
      rules: [{ type: 'pull_request', parameters: { required_approving_review_count: REVIEW_COUNT, dismiss_stale_reviews_on_push: false, require_code_owner_review: false, require_last_push_approval: false, required_review_thread_resolution: false } }],
    };
  }
  return null;
}

// pr: { number, approvals: [{ state, author, authorType? }] }. A bot approval does not count.
function approvalGate(c, pr) {
  if (c.approvalEnforcement === 'off') return { blocked: false, mechanism: null, reason: 'approvalEnforcement is off' };
  const humans = (pr.approvals || []).filter(a => a.state === 'APPROVED' && a.authorType !== 'Bot').length;
  if (humans >= REVIEW_COUNT) return { blocked: false, mechanism: c.approvalEnforcement, reason: 'human approval present' };
  return { blocked: true, mechanism: c.approvalEnforcement, reason: `PR #${pr.number} has no human approval` };
}

module.exports = { loadConfig, validate, defaultPluginRoot, approvalGate, approvalPayload, DEFAULTS, MODES };
