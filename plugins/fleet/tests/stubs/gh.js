#!/usr/bin/env node
'use strict';
// gh stub for the fleet fixture tests. Stateful through files in GH_STUB_DIR:
//   issues.json   base issues [{number,title,body,labels[],state}]
//   labels.json   label overrides written by `issue edit`  {number: [labels]}
//   prs.json      pull requests [{number,title,body,state,headRefName,headRefOid,isDraft,url,repo}]
//   comments.json {"<repo>#<number>": [{id, body, created_at}]}, keyed by the repo the
//                 comment was written to (`issue comment` and `pr comment` alike)
//   ci.json       {workflows:[{name,state}], runs:[{created_at}], fail:bool} for the
//                 Actions endpoints; absent means one active workflow and a run just now
//   writes.log    one line per write: "edit <n> +label -label" / "comment <repo> <n>" /
//                 "title <repo> <n> <new title>" (`pr edit --title`, which rewrites prs.json) /
//                 "merge-attempt <repo> <n> <args>" and "merge <repo> <n> <args>" (`pr merge`)
//   checks.json   {"<repo>#<number>": [{name, state, bucket}]} for `pr checks`
//   reads.log     one line per `pr view` / `pr checks`
// Branches, BLOCKER.md and .claude/standards.json come from the bare remote at
// GH_STUB_REMOTE.
const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');

const DIR = process.env.GH_STUB_DIR;
const REMOTE = process.env.GH_STUB_REMOTE;
const rd = (f, d) => { try { return JSON.parse(fs.readFileSync(path.join(DIR, f), 'utf8')); } catch { return d; } };
const wr = (f, v) => fs.writeFileSync(path.join(DIR, f), JSON.stringify(v, null, 2));
const log = line => fs.appendFileSync(path.join(DIR, 'writes.log'), line + '\n');
const out = v => process.stdout.write(typeof v === 'string' ? v : JSON.stringify(v));

const argv = process.argv.slice(2);
const flag = name => { const i = argv.indexOf(name); return i >= 0 ? argv[i + 1] : null; };
const flags = name => argv.flatMap((a, i) => (a === name ? [argv[i + 1]] : []));

function issues() {
  const over = rd('labels.json', {});
  return rd('issues.json', []).map(i => ({ ...i, labels: over[i.number] || i.labels || [] }));
}

const [a, b] = argv;
if (a === '--version') { out('gh version 0.0.0-stub\n'); process.exit(0); }

if (a === 'issue' && b === 'list') {
  const state = (flag('--state') || 'open').toUpperCase();
  const lim = Number(flag('--limit') || 1000);
  const list = issues().filter(i => state === 'ALL' || String(i.state).toUpperCase() === state).slice(0, lim)
    .map(i => ({ number: i.number, title: i.title, body: i.body || '', state: i.state, labels: i.labels.map(name => ({ name })) }));
  out(list); process.exit(0);
}
if (a === 'issue' && b === 'view') {
  const i = issues().find(x => x.number === Number(argv[2]));
  if (!i) { process.stderr.write('not found\n'); process.exit(1); }
  out({ number: i.number, title: i.title, body: i.body || '', state: i.state, labels: i.labels.map(name => ({ name })) }); process.exit(0);
}
if (a === 'issue' && b === 'edit') {
  const n = Number(argv[2]);
  const over = rd('labels.json', {});
  const cur = new Set((over[n] || (issues().find(x => x.number === n) || {}).labels || []));
  for (const l of flags('--add-label')) cur.add(l);
  for (const l of flags('--remove-label')) cur.delete(l);
  over[n] = [...cur]; wr('labels.json', over);
  log(`edit ${n} ${flags('--add-label').map(l => '+' + l).join(' ')} ${flags('--remove-label').map(l => '-' + l).join(' ')}`.trim());
  process.exit(0);
}
if ((a === 'issue' || a === 'pr') && b === 'comment') {
  const n = Number(argv[2]);
  const repo = flag('--repo');
  const body = fs.readFileSync(0, 'utf8');
  const all = rd('comments.json', {});
  const key = `${repo}#${n}`;
  all[key] = [...(all[key] || []), { id: Date.now(), body, created_at: new Date().toISOString() }];
  wr('comments.json', all); log(`comment ${repo} ${n}`);
  out(`https://example.invalid/${n}#c\n`); process.exit(0);
}
if (a === 'pr' && b === 'edit') {
  const n = Number(argv[2]);
  const repo = flag('--repo');
  const title = flag('--title');
  if (title === null) { process.stderr.write('gh stub: pr edit needs --title\n'); process.exit(1); }
  const prs = rd('prs.json', []);
  const p = prs.find(x => x.number === n && (!x.repo || x.repo === repo));
  if (!p) { process.stderr.write(`gh stub: no PR #${n} in ${repo}\n`); process.exit(1); }
  p.title = title; wr('prs.json', prs); log(`title ${repo} ${n} ${title}`);
  out(`https://example.invalid/pr/${n}\n`); process.exit(0);
}
// pr view, pr checks and pr merge serve the merge stage. Each read is logged to
// reads.log ("view <repo> <n>" / "checks <repo> <n>"). A PR's mergeable
// defaults to UNKNOWN and its baseRefName to main.
if (a === 'pr' && b === 'view') {
  const n = Number(argv[2]);
  const repo = flag('--repo');
  const p = rd('prs.json', []).find(x => x.number === n && (!x.repo || x.repo === repo));
  if (!p) { process.stderr.write(`GraphQL: Could not resolve to a PullRequest with the number of ${n}. (repository.pullRequest)\n`); process.exit(1); }
  fs.appendFileSync(path.join(DIR, 'reads.log'), `view ${repo} ${n}\n`);
  out({ number: p.number, state: p.state, baseRefName: p.baseRefName || 'main', headRefOid: p.headRefOid, mergeable: p.mergeable || 'UNKNOWN', mergeCommit: p.mergeCommit || null });
  process.exit(0);
}
// checks.json {"<repo>#<n>": [{name, state, bucket}]}; absent is gh's "no checks
// reported". Like gh, a failed check exits 1 and a pending one 8, after the JSON.
// A PR with pushAfterChecks has its head moved to that sha once its checks are read.
if (a === 'pr' && b === 'checks') {
  const n = Number(argv[2]);
  const repo = flag('--repo');
  fs.appendFileSync(path.join(DIR, 'reads.log'), `checks ${repo} ${n}\n`);
  const list = rd('checks.json', {})[`${repo}#${n}`];
  const prs = rd('prs.json', []);
  const p = prs.find(x => x.number === n && (!x.repo || x.repo === repo));
  if (p && p.pushAfterChecks) { p.headRefOid = p.pushAfterChecks; delete p.pushAfterChecks; wr('prs.json', prs); }
  if (!list) { process.stderr.write(`no checks reported on the '${p ? p.headRefName : n}' branch\n`); process.exit(1); }
  out(list);
  process.exit(list.some(c => c.bucket === 'fail' || c.bucket === 'cancel') ? 1 : list.some(c => c.bucket === 'pending') ? 8 : 0);
}
// Every attempt is logged "merge-attempt <repo> <n> <args>"; a merge that lands,
// "merge <repo> <n> <args>". --match-head-commit other than the head fails as gh does.
if (a === 'pr' && b === 'merge') {
  const n = Number(argv[2]);
  const repo = flag('--repo');
  const rest = argv.slice(3).filter((x, i, all) => x !== '--repo' && all[i - 1] !== '--repo').join(' ');
  log(`merge-attempt ${repo} ${n} ${rest}`);
  const prs = rd('prs.json', []);
  const p = prs.find(x => x.number === n && (!x.repo || x.repo === repo));
  if (!p) { process.stderr.write(`GraphQL: Could not resolve to a PullRequest with the number of ${n}. (repository.pullRequest)\n`); process.exit(1); }
  if (String(p.state).toUpperCase() !== 'OPEN') { process.stderr.write(`X Pull request ${repo}#${n} can't be merged: it is ${String(p.state).toLowerCase()}\n`); process.exit(1); }
  const match = flag('--match-head-commit');
  if (match !== null && match !== p.headRefOid) { process.stderr.write('GraphQL: Head branch was modified. Review and try the merge again. (mergePullRequest)\n'); process.exit(1); }
  p.state = 'MERGED'; p.mergeCommit = { oid: 'c'.repeat(37) + String(n).padStart(3, '0').slice(-3) };
  wr('prs.json', prs); log(`merge ${repo} ${n} ${rest}`);
  process.exit(0);
}
if (a === 'pr' && b === 'list') {
  const repo = flag('--repo');
  out(rd('prs.json', []).filter(p => !p.repo || p.repo === repo)); process.exit(0);
}
if (a === 'label' && b === 'list') {
  const names = new Set(); for (const i of issues()) for (const l of i.labels) names.add(l);
  for (const l of ['agent-ready', 'cell:queued', 'cell:active', 'cell:awaiting-review', 'cell:blocked', 'cell:merged', 'cell:contract-change', 'worker:a', 'worker:x']) names.add(l);
  out([...names]); process.exit(0);
}
if (a === 'api') {
  const ep = b;
  if (/\/branches/.test(ep)) {
    const names = execFileSync('git', ['--git-dir', REMOTE, 'for-each-ref', '--format=%(refname:short)', 'refs/heads'], { encoding: 'utf8' }).trim().split('\n').filter(Boolean);
    out(names.join('\n') + '\n'); process.exit(0);   // one name per line, as --jq '.[].name' prints
  }
  if (/\/actions\/(workflows|runs)/.test(ep)) {
    const ci = rd('ci.json', {});
    if (ci.fail) { process.stderr.write('gh: HTTP 500\n'); process.exit(1); }
    if (/\/actions\/workflows/.test(ep)) out({ workflows: ci.workflows || [{ name: 'ci', state: 'active' }] });
    else out({ workflow_runs: ci.runs || [{ created_at: new Date().toISOString() }] });
    process.exit(0);
  }
  let m;
  if ((m = /contents\/(.*?BLOCKER\.md)\?ref=(.+)$/.exec(ep))) {
    try { execFileSync('git', ['--git-dir', REMOTE, 'cat-file', '-e', `${m[2]}:${m[1]}`], { stdio: 'ignore' }); process.exit(0); } catch { process.exit(1); }
  }
  // The manifest on the remote's default branch (its HEAD), raw, as the
  // Accept: application/vnd.github.raw+json read prints; absent is a 404.
  if (/^repos\/[^/]+\/[^/]+\/contents\/\.claude\/standards\.json$/.test(ep)) {
    try { out(execFileSync('git', ['--git-dir', REMOTE, 'show', 'HEAD:.claude/standards.json'], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] })); process.exit(0); }
    catch { process.stderr.write('gh: Not Found (HTTP 404)\n'); process.exit(1); }
  }
  if ((m = /repos\/(.+?)\/issues\/(\d+)\/comments/.exec(ep))) {
    const all = rd('comments.json', {});
    const list = all[`${m[1]}#${Number(m[2])}`] || [];
    // One JSON value per line, as --paginate --jq '... | @json' prints.
    const jq = flag('--jq') || '';
    const rows = /\.body/.test(jq) && !/id/.test(jq) ? list.map(c => c.body) : list.map(c => ({ id: c.id, body: c.body, created_at: c.created_at }));
    out(rows.map(v => JSON.stringify(v)).join('\n') + (rows.length ? '\n' : ''));
    process.exit(0);
  }
  out('[]'); process.exit(0);
}
process.stderr.write(`gh stub: unhandled ${argv.join(' ')}\n`);
process.exit(1);
