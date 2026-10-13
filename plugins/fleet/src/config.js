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
const WORKER_ID = /^[A-Za-z0-9_-]+$/;

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

function validate(raw, baseDir) {
  const c = { ...DEFAULTS, ...raw, models: { ...DEFAULTS.models, ...(raw.models || {}) } };

  if (typeof c.repo !== 'string' || !/^[\w.-]+\/[\w.-]+$/.test(c.repo)) fail('repo must be "owner/name"');
  if (!Number.isInteger(c.epic) || c.epic <= 0) fail('epic must be a positive issue number');

  if (!Array.isArray(c.targets) || c.targets.length === 0) fail('targets must list at least one {repo, localPath, defaultBranch}');
  c.targets = c.targets.map((t, i) => {
    if (!t || typeof t.repo !== 'string') fail(`targets[${i}].repo is required`);
    if (typeof t.localPath !== 'string') fail(`targets[${i}].localPath is required`);
    return {
      repo: t.repo.includes('/') ? t.repo : `${c.repo.split('/')[0]}/${t.repo}`,
      localPath: path.resolve(baseDir, t.localPath),
      defaultBranch: t.defaultBranch || 'main',
    };
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
  if (typeof c.maxBudgetUsd !== 'number' || c.maxBudgetUsd <= 0) fail('maxBudgetUsd must be a positive number');
  if (!PERMISSION_MODES.has(c.permissionMode)) fail(`permissionMode [${c.permissionMode}] is not a Claude Code permission mode`);
  if (c.permissionPrompts !== 'none' && c.permissionPrompts !== 'host') fail('permissionPrompts must be "none" or "host"');

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

module.exports = { loadConfig, validate, defaultPluginRoot, DEFAULTS, MODES };
