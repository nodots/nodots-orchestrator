'use strict';

/*
 * Drafts a target's standards manifest (.claude/standards.json) from what the
 * clone already has. The contract is the agentic-work-packages plugin's
 * references/standards.md; the validator is its check-standards.js, which the
 * CLI runs against the draft. This module only reads.
 *
 * It never guesses a check it cannot see: a clone with no package.json gets an
 * empty checks[], which does not validate, and a note saying what to add.
 */

const fs = require('fs');
const path = require('path');

// package.json scripts that become checks, in this order, and the command each runs.
const SCRIPT_CHECKS = [
  ['lint', 'npm run lint'],
  ['typecheck', 'npm run typecheck'],
  ['build', 'npm run build'],
  ['test', 'npm test'],
];

// Root documents that become rules, in this order. The worker contract
// (.claude/worker-contract.md) is never a rule.
const RULE_DOCS = ['CLAUDE.md', 'CONTRIBUTING.md', 'AGENTS.md'];

const isFile = (p) => { try { return fs.statSync(p).isFile(); } catch { return false; } };

// draftManifest(localPath) -> { manifest, notes }
// Throws when package.json exists but cannot be read as JSON.
function draftManifest(localPath) {
  const notes = [];
  const checks = [];

  const pkgPath = path.join(localPath, 'package.json');
  if (isFile(pkgPath)) {
    let pkg;
    try { pkg = JSON.parse(fs.readFileSync(pkgPath, 'utf8')); }
    catch (e) { throw new Error(`${pkgPath}: not valid JSON: ${e.message}`); }
    const scripts = pkg && typeof pkg.scripts === 'object' && pkg.scripts !== null ? pkg.scripts : {};
    const found = SCRIPT_CHECKS.filter(([name]) => typeof scripts[name] === 'string');
    const missing = SCRIPT_CHECKS.filter(([name]) => typeof scripts[name] !== 'string').map(([name]) => name);
    for (const [name, command] of found) checks.push({ name, command });
    if (found.length) notes.push(`package.json: checks from scripts ${found.map(([n]) => n).join(', ')}`);
    else notes.push("package.json has none of the scripts lint, typecheck, build, test: checks[] is empty; add the repo's check commands before this validates");
    if (found.length && missing.length) notes.push(`package.json has no script ${missing.join(', ')}`);
  } else {
    notes.push("no package.json: checks[] is empty; add the repo's check commands before this validates");
  }

  const rules = [];
  for (const doc of RULE_DOCS) {
    if (isFile(path.join(localPath, doc))) rules.push({ doc, check: null });
  }
  const absent = RULE_DOCS.filter((d) => !rules.some((r) => r.doc === d));
  if (rules.length) notes.push(`rules from ${rules.map((r) => r.doc).join(', ')}, each with no check`);
  if (absent.length) notes.push(`no ${absent.join(', ')} at the root`);

  return { manifest: { version: 1, checks, rules }, notes };
}

module.exports = { draftManifest, SCRIPT_CHECKS, RULE_DOCS };
