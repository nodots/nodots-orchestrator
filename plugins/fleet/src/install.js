'use strict';

/*
 * Installing the worker files in a target repo.
 *
 * A target commits copies of the plugin's worker hooks, its worker contract
 * and the hook registrations of settings-snippet.json, because an isolated or
 * cloud worker sees only what the repo commits. plan() compares each with the
 * target's base ref (launch.js baseRef); apply() writes the ones that differ
 * on a new branch cut from that ref, commits once under the clone's identity
 * and pushes. Nothing here opens a PR. doctor() reports the same comparison.
 */

const fs = require('fs');
const path = require('path');
const { run } = require('./exec');
const launch = require('./launch');

const SETTINGS = '.claude/settings.json';

// [target path, source path relative to pluginRoot], settings.json excepted:
// it is merged, never copied.
const COPIES = [
  ['.claude/hooks/enforce-scope.js', 'hooks/enforce-scope.js'],
  ['.claude/hooks/require-handoff.js', 'hooks/require-handoff.js'],
  ['.claude/hooks/standards-preamble.js', 'hooks/standards-preamble.js'],
  ['.claude/worker-contract.md', 'skills/agentic-work-packages/assets/worker-contract.md'],
];
const SNIPPET = 'skills/agentic-work-packages/assets/settings-snippet.json';

function pluginVersion(cfg) {
  const file = path.join(cfg.pluginRoot, '.claude-plugin', 'plugin.json');
  let v;
  try { v = JSON.parse(fs.readFileSync(file, 'utf8')).version; } catch (e) { throw new Error(`cannot read the plugin version from ${file}: ${e.message}`); }
  if (typeof v !== 'string' || !v) throw new Error(`${file} has no version`);
  return v;
}

function readSnippet(cfg) {
  const file = path.join(cfg.pluginRoot, SNIPPET);
  const text = fs.readFileSync(file, 'utf8');
  let json;
  try { json = JSON.parse(text); } catch (e) { throw new Error(`${file} is not valid JSON (${e.message})`); }
  return { text, json };
}

// Each registration in the snippet: { event, matcher, group, hook }.
// A group without a matcher matches as "".
function registrations(snippet) {
  const out = [];
  for (const [event, groups] of Object.entries(snippet.hooks || {})) {
    for (const group of groups) for (const hook of group.hooks || []) out.push({ event, matcher: group.matcher || '', group, hook });
  }
  return out;
}

// A registration is present when a group of its event with the same matcher
// runs the same command.
function hasRegistration(settings, r) {
  const groups = settings && settings.hooks && Array.isArray(settings.hooks[r.event]) ? settings.hooks[r.event] : [];
  return groups.some(g => g && (g.matcher || '') === r.matcher && Array.isArray(g.hooks)
    && g.hooks.some(h => h && h.command === r.hook.command));
}

// settings with each missing registration added: into a group of the same
// event and matcher when there is one, else as a new group. Every other key
// and entry is kept.
function mergeSettings(settings, missing) {
  const s = JSON.parse(JSON.stringify(settings));
  if (!s.hooks || typeof s.hooks !== 'object' || Array.isArray(s.hooks)) s.hooks = {};
  for (const r of missing) {
    if (!Array.isArray(s.hooks[r.event])) s.hooks[r.event] = [];
    const g = s.hooks[r.event].find(x => x && (x.matcher || '') === r.matcher && Array.isArray(x.hooks));
    if (g) g.hooks.push({ ...r.hook });
    else s.hooks[r.event].push({ ...r.group, hooks: [{ ...r.hook }] });
  }
  return s;
}

// readAt(cfg, cwd, ref, file) -> { ok, text } where text is null for a file
// absent from ref | { ok:false, error }
function readAt(cfg, cwd, ref, file) {
  const g = args => run(cfg.bins.git, ['-C', cwd, ...args], { timeoutMs: 60000 });
  const why = r => r.error || r.stderr.trim() || `exit ${r.status}`;
  const ls = g(['ls-tree', '--name-only', ref, '--', file]);
  if (ls.status !== 0) return { ok: false, error: `git ls-tree ${ref} -- ${file} failed in ${cwd}: ${why(ls)}` };
  if (!ls.stdout.trim()) return { ok: true, text: null };
  const show = g(['show', `${ref}:${file}`]);
  if (show.status !== 0) return { ok: false, error: `git show ${ref}:${file} failed in ${cwd}: ${why(show)}` };
  return { ok: true, text: show.stdout };
}

// plan(cfg, target) -> { ref, files: [{ path, status, content }], registrations: [{ event, command, present }] }
// status is add, update or same; content is what --apply writes. Throws on a
// base ref or a settings.json that cannot be read.
function plan(cfg, target) {
  const ref = launch.baseRef(target);
  const files = [];
  for (const [dest, src] of COPIES) {
    const want = fs.readFileSync(path.join(cfg.pluginRoot, src), 'utf8');
    const have = readAt(cfg, target.localPath, ref, dest);
    if (!have.ok) throw new Error(have.error);
    files.push({ path: dest, status: have.text === null ? 'add' : have.text === want ? 'same' : 'update', content: want });
  }
  const snippet = readSnippet(cfg);
  const regs = registrations(snippet.json);
  const have = readAt(cfg, target.localPath, ref, SETTINGS);
  if (!have.ok) throw new Error(have.error);
  let settings = null;
  if (have.text !== null) {
    try { settings = JSON.parse(have.text); } catch (e) { throw new Error(`${SETTINGS} on ${ref} in ${target.localPath} is not valid JSON (${e.message}); fix it by hand before installing`); }
    if (!settings || typeof settings !== 'object' || Array.isArray(settings)) throw new Error(`${SETTINGS} on ${ref} in ${target.localPath} is not a JSON object; fix it by hand before installing`);
  }
  const missing = regs.filter(r => !hasRegistration(settings, r));
  if (settings === null) files.push({ path: SETTINGS, status: 'add', content: snippet.text });
  else if (missing.length) files.push({ path: SETTINGS, status: 'update', content: JSON.stringify(mergeSettings(settings, missing), null, 2) + '\n' });
  else files.push({ path: SETTINGS, status: 'same', content: null });
  return { ref, files, registrations: regs.map(r => ({ event: r.event, command: r.hook.command, present: !missing.includes(r) })) };
}

function installBranch(version) { return `chore/install-agentic-work-packages-${version}`; }

// The identity as author and committer, as launch.js commits the scope.
function commitAs(identity) {
  return {
    args: ['-c', `user.name=${identity.name}`, '-c', `user.email=${identity.email}`],
    env: { ...process.env, GIT_AUTHOR_NAME: identity.name, GIT_AUTHOR_EMAIL: identity.email, GIT_COMMITTER_NAME: identity.name, GIT_COMMITTER_EMAIL: identity.email },
  };
}

// apply(cfg, target, log) -> { ok, branch, worktree, plan, prCommand } | { ok, branch:null, plan } when
// every file is same | { ok:false, stage, error }
function apply(cfg, target, log = () => {}) {
  const git = cfg.bins.git;
  const g = (args, cwd) => run(git, ['-C', cwd || target.localPath, ...args], { timeoutMs: 120000 });
  const why = r => r.error || r.stderr.trim() || `exit ${r.status}`;
  if (!fs.existsSync(target.localPath)) return { ok: false, stage: 'clone', error: `no clone at ${target.localPath}` };

  const identity = launch.readIdentity(git, target.localPath);
  if (!identity.ok) return { ...identity, stage: `launch-${identity.stage}` };

  const f = g(['fetch', 'origin', '--prune']);
  if (f.status !== 0) return { ok: false, stage: 'fetch', error: why(f) };
  const e = launch.baseRefExists(cfg, target);
  if (!e.ok || !e.exists) return { ok: false, stage: 'base-ref', error: `${target.repo}: ${launch.baseRef(target)} ${e.ok ? 'does not exist' : `cannot be read: ${e.error}`} in ${target.localPath}` };

  const p = plan(cfg, target);
  const todo = p.files.filter(x => x.status !== 'same');
  if (!todo.length) return { ok: true, branch: null, plan: p };

  const version = pluginVersion(cfg);
  const branch = installBranch(version);
  const remote = g(['ls-remote', '--heads', 'origin', `refs/heads/${branch}`]);
  if (remote.status !== 0) return { ok: false, stage: 'ls-remote', error: why(remote) };
  if (remote.stdout.trim()) return { ok: false, stage: 'branch-exists', error: `${branch} already exists on origin of ${target.repo}; merge or close its PR and delete the branch, then run fleet install again` };
  if (g(['rev-parse', '--verify', '--quiet', `refs/heads/${branch}`]).status === 0) return { ok: false, stage: 'branch-exists', error: `${branch} already exists in ${target.localPath}; delete it (git -C ${target.localPath} branch -D ${branch}) and its worktree, then run fleet install again` };
  const worktree = path.join(cfg.worktreesDir, `${target.repo.split('/').pop()}-install-agentic-work-packages-${version}`);
  if (fs.existsSync(worktree)) return { ok: false, stage: 'worktree', error: `${worktree} exists; remove it (git -C ${target.localPath} worktree remove ${worktree}), then run fleet install again` };

  fs.mkdirSync(cfg.worktreesDir, { recursive: true });
  const w = g(['worktree', 'add', '-q', '-b', branch, worktree, p.ref]);
  if (w.status !== 0) return { ok: false, stage: 'worktree', error: why(w) };
  for (const x of todo) {
    fs.mkdirSync(path.dirname(path.join(worktree, x.path)), { recursive: true });
    fs.writeFileSync(path.join(worktree, x.path), x.content);
    log(`${x.status} ${x.path}`);
  }
  const a = g(['add', '--', ...todo.map(x => x.path)], worktree);
  if (a.status !== 0) return { ok: false, stage: 'commit', error: why(a) };
  const as = commitAs(identity);
  const c = run(git, ['-C', worktree, ...as.args, 'commit', '-q', '-m', `chore: install agentic-work-packages ${version} worker files`], { timeoutMs: 120000, env: as.env });
  if (c.status !== 0) return { ok: false, stage: 'commit', error: why(c) };
  // Plain push, never forced.
  const push = g(['push', '-q', '-u', 'origin', branch], worktree);
  if (push.status !== 0) return { ok: false, stage: 'push', error: why(push) };
  // The pushed branch is the result; the worktree and the local branch are
  // removed so the next install starts clean. A failure here is reported, the
  // push stands.
  const rm = g(['worktree', 'remove', worktree]);
  const del = rm.status === 0 ? g(['branch', '-q', '-D', branch]) : rm;
  if (del.status !== 0) log(`warning: ${branch} is pushed, but removing ${worktree} or the local branch failed: ${why(del)}`);
  const base = launch.baseBranch(target);
  const prCommand = `gh pr create --repo ${target.repo} --base ${base} --head ${branch} --title "chore: install agentic-work-packages ${version} worker files" --body "Installs the worker hooks, the worker contract and the hook registrations of agentic-work-packages ${version}, written by fleet install."`;
  return { ok: true, branch, worktree, plan: p, prCommand };
}

// doctor(cfg, target, check): one check per installed file, then one per
// snippet registration, against the base ref of the clone.
function doctor(cfg, target, check) {
  const fix = `run fleet install --target ${target.repo}`;
  let p;
  try { p = plan(cfg, target); } catch (e) { check(false, `worker files in ${target.repo}`, `${e.message}; ${fix}`); return; }
  for (const x of p.files) {
    if (x.path === SETTINGS) {
      check(x.status !== 'add', `worker file ${x.path} in ${target.repo}`, x.status === 'add' ? `missing on ${p.ref}; ${fix}` : `present on ${p.ref}; its registrations follow`);
      continue;
    }
    check(x.status === 'same', `worker file ${x.path} in ${target.repo}`, x.status === 'same' ? `same as the plugin's on ${p.ref}`
      : `${x.status === 'add' ? 'missing' : 'differs from the plugin\'s'} on ${p.ref}; ${fix}`);
  }
  for (const r of p.registrations) {
    check(r.present, `hook registration ${r.event} in ${target.repo}`, r.present ? r.command
      : `${SETTINGS} on ${p.ref} does not register ${r.command}; ${fix}`);
  }
}

module.exports = { plan, apply, doctor, pluginVersion, installBranch, registrations, hasRegistration, mergeSettings, COPIES, SETTINGS };
