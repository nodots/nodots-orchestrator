'use strict';

/*
 * The tracker is the bus. This is the only module that talks to gh, so what
 * the runtime reads and writes there is listable in one place:
 *   reads:  issue list (with bodies), issue view, PR list, issue comments
 *   writes: add/remove one label, post one comment
 * It never edits an issue body or a SCOPE.json, and never touches a session.
 */

const { run, runJson } = require('./exec');

const PAGE_LIMIT = Number(process.env.FLEET_PAGE_LIMIT || 1000);

class Tracker {
  constructor(bins) { this.gh = bins.gh; this.git = bins.git; }

  // Open and closed: a merged package's issue is closed by GitHub.
  listIssues(repo) {
    const r = runJson(this.gh, ['issue', 'list', '--repo', repo, '--state', 'all', '--limit', String(PAGE_LIMIT),
      '--json', 'number,title,body,labels,state']);
    if (r.json === null) return { ok: false, error: r.error || r.stderr.trim() || `gh exited ${r.status}`, issues: [] };
    if (r.json.length >= PAGE_LIMIT) return { ok: false, error: `issue list filled the page limit of ${PAGE_LIMIT}; raise FLEET_PAGE_LIMIT`, issues: [], truncated: true };
    return { ok: true, issues: r.json.map(i => ({ ...i, labels: (i.labels || []).map(l => (typeof l === 'string' ? l : l.name)) })) };
  }

  viewIssue(repo, number) {
    const r = runJson(this.gh, ['issue', 'view', String(number), '--repo', repo, '--json', 'number,title,body,labels,state']);
    if (r.json === null) return { ok: false, error: r.error || r.stderr.trim() };
    return { ok: true, issue: { ...r.json, labels: (r.json.labels || []).map(l => l.name) } };
  }

  listPulls(repo) {
    const r = runJson(this.gh, ['pr', 'list', '--repo', repo, '--state', 'all', '--limit', String(PAGE_LIMIT),
      '--json', 'number,title,body,state,headRefName,headRefOid,isDraft,url']);
    if (r.json === null) return { ok: false, error: r.error || r.stderr.trim(), pulls: [] };
    return { ok: true, pulls: r.json };
  }

  listComments(repo, number) {
    // --paginate emits one result per page; one JSON value per line survives that.
    const r = run(this.gh, ['api', `repos/${repo}/issues/${number}/comments`, '--paginate', '--jq', '.[] | {id, body, created_at} | @json']);
    if (r.status !== 0) return { ok: false, error: r.error || r.stderr.trim(), comments: [] };
    const all = [];
    for (const line of r.stdout.split('\n')) { if (!line.trim()) continue; try { all.push(JSON.parse(line)); } catch { /* skip */ } }
    return { ok: true, comments: all };
  }

  addLabel(repo, number, label) {
    const r = run(this.gh, ['issue', 'edit', String(number), '--repo', repo, '--add-label', label]);
    return r.status === 0 ? { ok: true } : { ok: false, error: r.error || r.stderr.trim() };
  }

  removeLabel(repo, number, label) {
    const r = run(this.gh, ['issue', 'edit', String(number), '--repo', repo, '--remove-label', label]);
    return r.status === 0 ? { ok: true } : { ok: false, error: r.error || r.stderr.trim() };
  }

  comment(repo, number, body) {
    const r = run(this.gh, ['issue', 'comment', String(number), '--repo', repo, '--body-file', '-'], { input: body });
    return r.status === 0 ? { ok: true, url: r.stdout.trim() } : { ok: false, error: r.error || r.stderr.trim() };
  }

  // The CI state a worker would run under: enabled workflows, and the newest
  // workflow run on <branch>. One answer per repo and branch per Tracker, so a
  // cycle asks once however many packages target the repo. A failed query is
  // { ok:false }; the caller refuses on it and never treats it as healthy.
  ciStatus(repo, branch) {
    const key = `${repo}#${branch}`;
    this.ciCache = this.ciCache || new Map();
    if (this.ciCache.has(key)) return this.ciCache.get(key);
    const result = this.queryCi(repo, branch);
    this.ciCache.set(key, result);
    return result;
  }

  queryCi(repo, branch) {
    const w = runJson(this.gh, ['api', `repos/${repo}/actions/workflows?per_page=100`]);
    if (w.json === null || !Array.isArray(w.json.workflows)) return { ok: false, error: `workflows query for ${repo}: ${w.error || w.stderr.trim() || `gh exited ${w.status}`}` };
    const enabled = w.json.workflows.filter(x => x.state === 'active').length;
    const r = runJson(this.gh, ['api', `repos/${repo}/actions/runs?branch=${encodeURIComponent(branch)}&per_page=1`]);
    if (r.json === null || !Array.isArray(r.json.workflow_runs)) return { ok: false, error: `runs query for ${repo}@${branch}: ${r.error || r.stderr.trim() || `gh exited ${r.status}`}` };
    const last = r.json.workflow_runs[0];
    return { ok: true, enabledWorkflows: enabled, lastRunAt: last ? last.created_at : null };
  }

  // Does <branch> exist on the remote of the clone at localPath?
  remoteBranchExists(localPath, branch) {
    const r = run(this.git, ['-C', localPath, 'ls-remote', '--exit-code', '--heads', 'origin', branch], { timeoutMs: 60000 });
    if (r.status === 0) return { ok: true, exists: true, sha: r.stdout.trim().split(/\s/)[0] || null };
    if (r.status === 2) return { ok: true, exists: false, sha: null };
    return { ok: false, error: r.error || r.stderr.trim() };
  }
}

module.exports = { Tracker };
