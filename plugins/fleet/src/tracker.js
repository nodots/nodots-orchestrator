'use strict';

/*
 * The tracker is the bus. This is the only module that talks to gh, so what
 * the runtime reads and writes there is listable in one place:
 *   reads:  issue list (with bodies), issue view, PR list, PR view, PR checks,
 *           issue comments, an issue's timeline (who applied each label), the
 *           login gh runs as
 *   writes: add/remove one label, post one comment, post one PR comment on a
 *           target repo, edit one PR title (the verify stage's retitle), merge
 *           one PR at a given head (the merge stage)
 * It never edits an issue body, a PR body or a SCOPE.json, and never touches a session.
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

  // For each label name, the login of its latest `labeled` event. The timeline
  // is oldest first, so a later event overwrites an earlier one. A deleted
  // account's events carry no actor: its login is null, which no coordinator
  // list matches.
  labelActors(repo, number) {
    const r = run(this.gh, ['api', `repos/${repo}/issues/${number}/timeline`, '--paginate',
      '--jq', '.[] | select(.event == "labeled") | {label: .label.name, actor: .actor.login} | @json']);
    if (r.status !== 0) return { ok: false, error: r.error || r.stderr.trim() || `gh exited ${r.status}` };
    const actors = {};
    for (const line of r.stdout.split('\n')) {
      if (!line.trim()) continue;
      let e;
      try { e = JSON.parse(line); } catch { return { ok: false, error: `timeline of #${number}: not JSON: ${line.slice(0, 80)}` }; }
      if (e && typeof e.label === 'string') actors[e.label] = typeof e.actor === 'string' ? e.actor : null;
    }
    return { ok: true, actors };
  }

  // The login gh runs as: the account fleet's own label writes come from.
  login() {
    const r = run(this.gh, ['api', 'user', '--jq', '.login']);
    const login = r.status === 0 ? r.stdout.trim() : '';
    return login ? { ok: true, login } : { ok: false, error: r.error || r.stderr.trim() || `gh exited ${r.status} with no login` };
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

  // A comment on a pull request in the repo that holds it (a target, not the host).
  prComment(repo, number, body) {
    const r = run(this.gh, ['pr', 'comment', String(number), '--repo', repo, '--body-file', '-'], { input: body });
    return r.status === 0 ? { ok: true, url: r.stdout.trim() } : { ok: false, error: r.error || r.stderr.trim() };
  }

  editPrTitle(repo, number, title) {
    const r = run(this.gh, ['pr', 'edit', String(number), '--repo', repo, '--title', title]);
    return r.status === 0 ? { ok: true } : { ok: false, error: r.error || r.stderr.trim() };
  }

  // One PR, fresh: the merge stage judges it at this head, not the list's.
  viewPull(repo, number) {
    const r = runJson(this.gh, ['pr', 'view', String(number), '--repo', repo, '--json', 'number,state,baseRefName,headRefOid,mergeable,mergeCommit']);
    if (r.json === null) return { ok: false, error: r.error || r.stderr.trim() || `gh exited ${r.status}` };
    return { ok: true, pull: r.json };
  }

  // The checks on a PR's head. gh exits 1 on a failed check and 8 on a pending
  // one with the JSON still printed, so the JSON is read whatever the status;
  // no JSON (no checks reported, or an error) is { ok:false }.
  prChecks(repo, number) {
    const r = run(this.gh, ['pr', 'checks', String(number), '--repo', repo, '--json', 'name,state,bucket']);
    let json = null;
    if (!r.error && [0, 1, 8].includes(r.status)) { try { json = JSON.parse(r.stdout); } catch { /* not JSON */ } }
    if (!Array.isArray(json)) return { ok: false, error: r.stderr.trim() || r.error || `gh exited ${r.status}` };
    return { ok: true, checks: json };
  }

  // A merge commit of <n>, only if its head is still <headSha>: a push after
  // the merge condition was checked fails the merge instead of landing unchecked.
  mergePr(repo, number, headSha) {
    const r = run(this.gh, ['pr', 'merge', String(number), '--repo', repo, '--merge', '--match-head-commit', headSha]);
    return r.status === 0 ? { ok: true } : { ok: false, error: r.stderr.trim() || r.error || `gh exited ${r.status}` };
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
