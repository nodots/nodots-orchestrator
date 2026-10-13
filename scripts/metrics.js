#!/usr/bin/env node
'use strict';
// metrics.js --repo <owner/name> [--last N] [--state-dir <dir>] [--pr-limit N] [--json]
//
// Delivery metrics for the last N merged packages, read through gh. Every value
// is labeled measured, estimated or unknown:
//   measured   read directly from a source and computed over every package
//   estimated  a lower bound or partial coverage: some input was missing, or an
//              input was itself estimated
//   unknown    no source; never printed as zero
// A package is an issue that a merged PR closes ("Closes #N" in the PR body).
// Cost comes from fleet logs: <state-dir>/logs/<issue>-<attempt>.log holds the
// `claude -p --output-format json` result, whose total_cost_usd is the figure
// the CLI reported for that attempt (plugins/fleet/src/launch.js:68, store.js:103).
// Env: GH_BIN overrides the gh binary, as in plugins/fleet/src/config.js.
// Exit 0 on a report, 1 when gh cannot be read, 2 on a usage error.
const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');
const { currentStamp } = require(path.join(
  __dirname, '..', 'plugins', 'agentic-work-packages', 'skills', 'agentic-work-packages', 'assets', 'scripts', 'stamp.js'));

const unknown = note => ({ value: null, label: 'unknown', display: 'unknown', note });

// The label of a figure built from several inputs: measured only when every
// input is measured and none is missing; any estimate or gap makes it an estimate.
function rollupLabel(inputs, expected) {
  const known = inputs.filter(i => i.label !== 'unknown');
  if (known.length === 0) return 'unknown';
  if (known.length < expected || known.some(i => i.label === 'estimated')) return 'estimated';
  return 'measured';
}

const linkedIssues = body => {
  const out = new Set();
  const re = /\b(?:closes|fixes|resolves)\s+#(\d+)/gi;
  let m;
  while ((m = re.exec(String(body || '')))) out.add(Number(m[1]));
  return [...out];
};
const when = s => { const t = Date.parse(s); return Number.isNaN(t) ? null : t; };
const commentBodies = pr => (pr.comments || []).map(c => (typeof c === 'string' ? c : c && c.body));

// readCosts(stateDir) -> { [issue]: { [attempt]: number|null } }; null when there is no state dir.
function readCosts(stateDir) {
  if (!stateDir) return null;
  const dir = path.join(stateDir, 'logs');
  const out = {};
  for (const f of fs.readdirSync(dir)) {
    const m = /^(\d+)-(\d+)\.log$/.exec(f);
    if (!m) continue;
    let cost = null;
    const lines = fs.readFileSync(path.join(dir, f), 'utf8').split('\n');
    for (let i = lines.length - 1; i >= 0 && cost === null; i--) {
      let j;
      try { j = JSON.parse(lines[i]); } catch { continue; }
      if (j && j.type === 'result' && Number.isFinite(j.total_cost_usd) && j.total_cost_usd >= 0) cost = j.total_cost_usd;
    }
    (out[Number(m[1])] = out[Number(m[1])] || {})[Number(m[2])] = cost;
  }
  return out;
}

// A package's cost: every attempt 1..max recorded -> measured; some recorded -> a
// lower bound, estimated; none -> unknown.
function packageCost(attempts) {
  if (!attempts) return unknown('no fleet log for this package');
  const max = Math.max(...Object.keys(attempts).map(Number));
  const recorded = [];
  for (let n = 1; n <= max; n++) if (typeof attempts[n] === 'number') recorded.push(attempts[n]);
  if (recorded.length === 0) return unknown('fleet log has no result line with total_cost_usd');
  const value = recorded.reduce((a, b) => a + b, 0);
  return { value, label: recorded.length === max ? 'measured' : 'estimated', display: `$${value.toFixed(2)}` };
}

// compute({ prs, issues, costs, last }) -> { packages, metrics, notes }
// prs: gh pr list JSON; issues: { [n]: { createdAt? } }; costs: readCosts() or null.
function compute({ prs, issues, costs, last }) {
  const notes = [];
  const byPkg = new Map();
  let unlinked = 0;
  for (const pr of prs) {
    const links = linkedIssues(pr.body);
    if (links.length === 0) unlinked++;
    for (const n of links) { if (!byPkg.has(n)) byPkg.set(n, []); byPkg.get(n).push(pr); }
  }
  if (unlinked) notes.push(`${unlinked} PRs carry no "Closes #<issue>" and are not attributed to a package`);

  const merged = [...byPkg.entries()]
    .map(([issue, list]) => ({ issue, prs: list.slice().sort((a, b) => (when(a.createdAt) || 0) - (when(b.createdAt) || 0) || a.number - b.number) }))
    .filter(p => p.prs.some(x => String(x.state).toUpperCase() === 'MERGED'))
    .map(p => ({ ...p, mergedAt: Math.max(...p.prs.filter(x => String(x.state).toUpperCase() === 'MERGED').map(x => when(x.mergedAt) || 0)) }))
    .sort((a, b) => b.mergedAt - a.mergedAt)
    .slice(0, last);
  const N = merged.length;

  const metrics = {};
  if (N === 0) {
    const none = unknown('no merged package in the window');
    for (const k of ['firstPassMergeRate', 'prsPerPackage', 'stampCurrency', 'hoursOpenToMerge', 'costPerMergedPackage', 'costTotal']) metrics[k] = none;
    return { packages: [], metrics, notes, costsRead: Boolean(costs) };
  }

  const first = merged.filter(p => String(p.prs[0].state).toUpperCase() === 'MERGED').length;
  metrics.firstPassMergeRate = { value: 100 * first / N, label: 'measured', display: `${(100 * first / N).toFixed(1)}% (${first} of ${N} packages)` };

  const prCount = merged.reduce((a, p) => a + p.prs.length, 0);
  metrics.prsPerPackage = { value: prCount / N, label: 'measured', display: `${(prCount / N).toFixed(2)} (${prCount} PRs, ${N} packages)` };

  const ready = merged.flatMap(p => p.prs).filter(pr => /^\[READY\]:/.test(String(pr.title || '')));
  const judged = ready.filter(pr => pr.headRefOid && Array.isArray(pr.comments));
  if (judged.length === 0) {
    metrics.stampCurrency = unknown(ready.length ? 'READY PRs came back without head sha or comments' : 'no READY PR in the window');
  } else {
    const cur = judged.filter(pr => currentStamp({ headSha: pr.headRefOid, comments: commentBodies(pr) })).length;
    metrics.stampCurrency = {
      value: 100 * cur / judged.length,
      label: judged.length === ready.length ? 'measured' : 'estimated',
      display: `${(100 * cur / judged.length).toFixed(1)}% (${cur} of ${judged.length} READY PRs)`,
    };
    if (judged.length < ready.length) notes.push(`stamp currency: ${ready.length - judged.length} READY PRs had no head sha or comments and are excluded`);
  }

  const hrs = merged
    .map(p => ({ t0: when((issues[p.issue] || {}).createdAt), t1: p.mergedAt }))
    .filter(h => h.t0 !== null && h.t1);
  if (hrs.length === 0) {
    metrics.hoursOpenToMerge = unknown('gh did not return an issue creation time for any package');
  } else {
    const mean = hrs.reduce((a, h) => a + (h.t1 - h.t0) / 3600000, 0) / hrs.length;
    metrics.hoursOpenToMerge = {
      value: mean,
      label: hrs.length === N ? 'measured' : 'estimated',
      display: `${mean.toFixed(1)} (mean of ${hrs.length} of ${N} packages)`,
    };
  }

  const packages = merged.map(p => ({ issue: p.issue, prs: p.prs.map(x => x.number), cost: costs ? packageCost(costs[p.issue]) : unknown('no --state-dir given') }));
  const known = packages.map(p => p.cost).filter(c => c.label !== 'unknown');
  if (!costs) {
    metrics.costTotal = metrics.costPerMergedPackage = unknown('no --state-dir given, so no fleet log was read');
  } else if (known.length === 0) {
    metrics.costTotal = metrics.costPerMergedPackage = unknown('no package has a fleet log with total_cost_usd');
  } else {
    const label = rollupLabel(packages.map(p => p.cost), N);
    const total = known.reduce((a, c) => a + c.value, 0);
    metrics.costTotal = { value: total, label, display: `$${total.toFixed(2)} (${known.length} of ${N} packages have log cost)` };
    metrics.costPerMergedPackage = { value: total / known.length, label, display: `$${(total / known.length).toFixed(2)} (mean of ${known.length} packages with log cost)` };
  }
  return { packages, metrics, notes, costsRead: Boolean(costs) };
}

const NAMES = {
  firstPassMergeRate: 'first-pass merge rate',
  prsPerPackage: 'PRs per package',
  stampCurrency: 'stamp currency',
  hoursOpenToMerge: 'hours open to merge',
  costPerMergedPackage: 'cost per merged package',
  costTotal: 'cost total',
};

function render(repo, last, r) {
  const lines = [`# ${repo}: last ${last} merged packages requested, ${r.packages.length} found`];
  for (const [k, name] of Object.entries(NAMES)) {
    const m = r.metrics[k];
    lines.push(`${name}: ${m.label === 'unknown' ? 'unknown' : m.display} [${m.label}]`);
    if (m.label === 'unknown') lines.push(`# ${name}: ${m.note}`);
  }
  if (r.costsRead) {
    for (const p of r.packages) {
      lines.push(`package ${p.issue} cost: ${p.cost.label === 'unknown' ? 'unknown' : p.cost.display} [${p.cost.label}]`);
    }
  }
  for (const n of r.notes) lines.push(`# ${n}`);
  return lines.join('\n') + '\n';
}

function gh(args) {
  return execFileSync(process.env.GH_BIN || 'gh', args, { encoding: 'utf8', timeout: 120000, maxBuffer: 64 * 1024 * 1024, stdio: ['ignore', 'pipe', 'pipe'] });
}

function parseArgs(argv) {
  const o = { last: 10, prLimit: 200, json: false };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--json') o.json = true;
    else if (['--repo', '--last', '--state-dir', '--pr-limit'].includes(a)) {
      if (argv[i + 1] === undefined) throw new Error(`${a} needs a value`);
      const v = argv[++i];
      if (a === '--repo') o.repo = v;
      else if (a === '--state-dir') o.stateDir = v;
      else {
        const n = Number(v);
        if (!Number.isInteger(n) || n < 1) throw new Error(`${a} needs a positive integer, got ${v}`);
        if (a === '--last') o.last = n; else o.prLimit = n;
      }
    } else throw new Error(`unknown argument ${a}`);
  }
  if (!o.repo || !/^[\w.-]+\/[\w.-]+$/.test(o.repo)) throw new Error('--repo <owner/name> is required');
  return o;
}

function main() {
  let o;
  try { o = parseArgs(process.argv.slice(2)); } catch (e) {
    console.error(`metrics: ${e.message}\nusage: metrics.js --repo <owner/name> [--last N] [--state-dir <dir>] [--pr-limit N] [--json]`);
    process.exit(2);
  }
  let prs;
  try {
    prs = JSON.parse(gh(['pr', 'list', '--repo', o.repo, '--state', 'all', '--limit', String(o.prLimit),
      '--json', 'number,title,body,state,headRefOid,createdAt,mergedAt,comments']));
  } catch (e) {
    console.error(`metrics: cannot read pull requests for ${o.repo}: ${(e.stderr || e.message || '').toString().trim()}`);
    process.exit(1);
  }
  let costs;
  try { costs = readCosts(o.stateDir); } catch (e) {
    console.error(`metrics: cannot read fleet logs in ${o.stateDir}: ${e.message}`);
    process.exit(1);
  }

  // Issue creation times, only for the packages inside the window.
  const issues = {};
  const pre = compute({ prs, issues, costs, last: o.last });
  const issueNotes = [];
  for (const p of pre.packages) {
    try { issues[p.issue] = JSON.parse(gh(['issue', 'view', String(p.issue), '--repo', o.repo, '--json', 'createdAt'])); }
    catch (e) { issueNotes.push(`issue #${p.issue}: gh issue view failed: ${(e.stderr || e.message || '').toString().trim()}`); }
  }
  const r = compute({ prs, issues, costs, last: o.last });
  r.notes.push(...issueNotes);

  if (o.json) process.stdout.write(JSON.stringify({ repo: o.repo, last: o.last, ...r }, null, 2) + '\n');
  else process.stdout.write(render(o.repo, o.last, r));
}

if (require.main === module) main();
module.exports = { compute, readCosts, packageCost, rollupLabel };
