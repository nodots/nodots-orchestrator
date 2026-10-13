'use strict';

/*
 * The package issue is the source of truth for SCOPE.json: the fenced json
 * block under its "### SCOPE.json" heading, per references/cell.md. This
 * module extracts it, validates it enough to refuse an unlaunchable package,
 * and derives the names the launch needs.
 */

const path = require('path');

const PATTERNS = new Set(['solo', 'implement+review', 'implement+test', 'gate-verify']);
const TIERS = new Set(['cheapest', 'default', 'strongest']);

// First whitespace-delimited token of the title, trailing punctuation
// stripped: the same rule sync-cells.sh uses, so both agree on the id.
function packageId(title) {
  return (String(title || '').trim().split(/\s+/)[0] || '').replace(/[^\w.\-]+$/, '');
}

// M1.3 -> m1-3 ; T5.0d -> t5-0d
function slug(id) {
  return String(id).toLowerCase().replace(/\./g, '-');
}

function worktreePath(worktreesDir, targetRepo, id) {
  const repoName = String(targetRepo).split('/').pop();
  return path.join(worktreesDir, `${repoName}-${slug(id)}`);
}

// extract(body) -> { scope, error }
function extract(body) {
  const text = String(body || '');
  const heading = /^#{2,4}\s*`?SCOPE\.json`?\s*$/im.exec(text);
  const from = heading ? heading.index + heading[0].length : 0;
  const fence = /```(?:json)?[^\n]*\n([\s\S]*?)\n```/m.exec(text.slice(from));
  if (!fence) return { scope: null, error: heading ? 'no fenced json block under the SCOPE.json heading' : 'no SCOPE.json heading and no fenced json block' };
  try {
    return { scope: JSON.parse(fence[1]), error: null };
  } catch (e) {
    return { scope: null, error: `SCOPE.json block is not valid JSON: ${e.message}` };
  }
}

function safeBranch(b) {
  if (typeof b !== 'string' || !b) return false;
  if (b.startsWith('-') || b.includes('..') || /\s/.test(b) || b.endsWith('/') || b.endsWith('.lock')) return false;
  return /^[A-Za-z0-9._\/-]+$/.test(b);
}

// validate(scope) -> [] or a list of reasons the package cannot be launched.
function validate(scope) {
  const problems = [];
  if (!scope || typeof scope !== 'object') return ['SCOPE.json is not an object'];
  if (!safeBranch(scope.branch)) problems.push(`branch [${scope.branch}] is missing or unsafe`);
  if (!Array.isArray(scope.allowedPaths) || scope.allowedPaths.length === 0) problems.push('allowedPaths is empty: a worker that may edit nothing cannot finish');
  if (scope.forbiddenPaths !== undefined && !Array.isArray(scope.forbiddenPaths)) problems.push('forbiddenPaths must be an array');
  if (scope.dependsOn !== undefined && !Array.isArray(scope.dependsOn)) problems.push('dependsOn must be an array of branch names');
  // A lane whose allowedPaths are also forbidden cannot be worked: the hook
  // denies every write and the worker ends in a BLOCKER.md it cannot resolve.
  // Exact duplicates and a forbidden "<dir>/**" that covers an allowed
  // "<dir>/..." are the two shapes seen in practice; wider glob algebra is not
  // attempted.
  if (Array.isArray(scope.allowedPaths) && Array.isArray(scope.forbiddenPaths)) {
    for (const a of scope.allowedPaths) {
      for (const f of scope.forbiddenPaths) {
        const dir = /^(.*?)\/\*\*$/.exec(f);
        if (a === f || (dir && (a === dir[1] || a.startsWith(dir[1] + '/')))) {
          problems.push(`allowedPaths [${a}] is covered by forbiddenPaths [${f}]; the lane cannot be worked`);
        }
      }
    }
  }
  const ex = scope.execution || {};
  if (ex.pattern !== undefined && !PATTERNS.has(ex.pattern)) problems.push(`execution.pattern [${ex.pattern}] is not one of ${[...PATTERNS].join(', ')}`);
  if (ex.model !== undefined && !TIERS.has(ex.model)) problems.push(`execution.model [${ex.model}] is not one of ${[...TIERS].join(', ')}`);
  if (ex.mode !== undefined && !['local', 'cloud'].includes(ex.mode)) problems.push(`execution.mode [${ex.mode}] is not local or cloud`);
  // The check that verifies the output is what lets a cheaper tier run unattended.
  if (ex.verifiedBy !== undefined && (typeof ex.verifiedBy !== 'string' || !ex.verifiedBy.trim())) problems.push('execution.verifiedBy must be a non-empty string naming the check that verifies the output');
  else if (ex.model === 'cheapest' && ex.verifiedBy === undefined) problems.push('execution.verifiedBy is required when execution.model is cheapest: name the test, schema, build or gate that verifies the output');
  return problems;
}

// What the cycle needs from an issue, or why it cannot have it.
function describe(issue) {
  const id = packageId(issue.title);
  const { scope, error } = extract(issue.body);
  if (error) return { id, scope: null, problems: [error] };
  const problems = validate(scope);
  return { id, scope, problems };
}

module.exports = { packageId, slug, worktreePath, extract, validate, describe, safeBranch, PATTERNS, TIERS };
