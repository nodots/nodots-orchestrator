'use strict';

/*
 * Promotion: a package becomes cell:queued when every branch it depends on
 * has merged. sync-cells.sh never emits cell:queued (coordination.md: the
 * coordinator sets it), so this is the one label the runtime adds itself.
 *
 * Pure. Input is the issue list (with bodies, for dependsOn) and the sync
 * state (for which branches have a merged PR). Output is a list of edits.
 */

const scope = require('./scope');

const labelsOf = i => (i.labels || []).map(l => (typeof l === 'string' ? l : l.name));

// Branches with a merged PR, from the sync state. A dependsOn entry is a
// branch name; it is satisfied when some package's PR on that branch merged.
function mergedBranches(syncState) {
  const set = new Set();
  for (const i of (syncState && syncState.issues) || []) {
    if (i.pr && String(i.pr.state).toUpperCase() === 'MERGED' && i.branch) set.add(i.branch);
  }
  return set;
}

// promote(issues, syncState) -> { edits: [{number, id, add, why}], held: [{number, id, why}] }
function promote(issues, syncState) {
  const merged = mergedBranches(syncState);
  const byNumber = new Map(((syncState && syncState.issues) || []).map(i => [i.number, i]));
  const edits = [];
  const held = [];

  for (const issue of issues) {
    if (String(issue.state || 'OPEN').toUpperCase() !== 'OPEN') continue;
    const labels = labelsOf(issue);
    if (!labels.includes('agent-ready')) continue;
    if (labels.some(l => l.startsWith('cell:'))) continue;   // already in the lifecycle

    const d = scope.describe(issue);
    if (d.problems.length) { held.push({ number: issue.number, id: d.id, why: `not promotable: ${d.problems.join('; ')}` }); continue; }

    const synced = byNumber.get(issue.number);
    if (synced && (synced.branchExists || synced.pr)) { held.push({ number: issue.number, id: d.id, why: 'branch or PR already exists; sync owns this label' }); continue; }

    const deps = d.scope.dependsOn || [];
    const unmet = deps.filter(b => !merged.has(b));
    if (unmet.length) { held.push({ number: issue.number, id: d.id, why: `waiting on ${unmet.join(', ')}` }); continue; }

    edits.push({ number: issue.number, id: d.id, add: 'cell:queued', why: deps.length ? `all of ${deps.join(', ')} merged` : 'no dependencies' });
  }
  return { edits, held };
}

module.exports = { promote, mergedBranches };
