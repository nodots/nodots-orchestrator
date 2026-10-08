'use strict';

/*
 * Workspace trust. Under `claude -p` the project's permissions.allow rules are
 * ignored unless the workspace has been trusted once, and Claude Code says so
 * on stderr: "Ignoring N permissions.allow entries from .claude/settings.json:
 * this workspace has not been trusted." A worker launched into an untrusted
 * clone can read but cannot commit, push or open a PR, so it ends with a
 * HANDOFF.md and no artifact. Trust is recorded per main-clone path in
 * ~/.claude.json (projects[<path>].hasTrustDialogAccepted); a linked worktree
 * inherits its clone's entry. The runtime checks before launching rather than
 * discovering it one denied command at a time.
 */

const fs = require('fs');
const path = require('path');
const os = require('os');
const { run } = require('./exec');

function configFile() { return process.env.CLAUDE_CONFIG_FILE || path.join(os.homedir(), '.claude.json'); }

// The key Claude Code uses: the main clone's top level, not the worktree.
function mainClonePath(gitBin, localPath) {
  const r = run(gitBin, ['-C', localPath, 'rev-parse', '--git-common-dir'], { timeoutMs: 15000 });
  if (r.status !== 0) return path.resolve(localPath);
  const common = path.resolve(localPath, r.stdout.trim());
  return path.dirname(common);
}

// isTrusted(gitBin, localPath) -> { trusted, key, file, error }
function isTrusted(gitBin, localPath) {
  const file = configFile();
  const key = mainClonePath(gitBin, localPath);
  let cfg;
  try { cfg = JSON.parse(fs.readFileSync(file, 'utf8')); }
  catch (e) { return { trusted: false, key, file, error: `cannot read ${file}: ${e.message}` }; }
  const entry = cfg.projects && cfg.projects[key];
  return { trusted: Boolean(entry && entry.hasTrustDialogAccepted), key, file, error: null };
}

function howToTrust(t) {
  return `run Claude Code interactively in ${t.key} once and accept the trust dialog, or set projects["${t.key}"].hasTrustDialogAccepted: true in ${t.file}`;
}

module.exports = { isTrusted, mainClonePath, howToTrust, configFile };
