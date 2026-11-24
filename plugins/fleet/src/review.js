'use strict';

/*
 * The review stage: for each cell:awaiting-reviewer PR (a verified PR short of
 * its repo's review policy, sync-cells.sh), launch the next configured
 * reviewer (config.js reviewers) and act on its verdict. It runs after verify
 * and before launch, so a failure's re-dispatch joins this cycle's launches.
 *
 * A reviewer is any command. It runs detached, as a worker does, in a fresh
 * worktree of its own detached at the PR head, with {prompt}, {worktree} and
 * {out} in its argv replaced by the prompt file, that worktree and the verdict
 * file. The prompt and the verdict live in the state directory, outside the
 * worktree. The verdict is one JSON object:
 *   {"verdict":"pass"|"fail","findings":[{"file","line","claim","evidence"}]}
 *
 * Read-only is checked after the run, for any command: the worktree's HEAD and
 * `git status --porcelain` are recorded before the spawn and compared after
 * the exit, and any difference discards the verdict (review-wrote). Writes
 * outside the worktree are not seen; the README says so. No reviewer flag is
 * parsed and no vendor is named.
 *
 * The only local memory is state.review[<target repo>]:
 *   inFlight  [{ pr, reviewer, headSha, issue, pid, startedAt, ... }], at most
 *             one per PR
 *   failed    { <pr>: { <reviewer>: { headSha, kind, reason, at } } }, so a
 *             reviewer is not run again at the head it failed, wrote at,
 *             timed out at or gave no valid verdict at
 * Which PRs wait is never stored: it is the sync's cell:awaiting-reviewer, every cycle.
 *
 * Dry run: no worktree, no spawn, no kill, no comment, no stamp. The report
 * says what would run, and what a finished run would post.
 */

const fs = require('fs');
const path = require('path');
const { run, spawnDetached, isAlive, signal } = require('./exec');
const scope = require('./scope');
const { baseRef } = require('./launch');

const short = sha => (typeof sha === 'string' ? sha.slice(0, 7) : String(sha));
const clip = (s, n) => String(s === undefined || s === null ? '' : s).replace(/\s+/g, ' ').trim().slice(0, n);
const oneLine = s => clip(s, 200);
const isOpen = p => Boolean(p) && String(p.state).toUpperCase() === 'OPEN';

const BRIEF = [
  'The change is presumed wrong until shown otherwise. Your task is to find a defect in it, not to confirm it.',
  'Read the package issue, the diff and the code it touches. Run the checks if they help you show a defect.',
  'Report each defect with file, line, claim and evidence: the file and line, what is wrong, and the input or state that shows it.',
  'Write only the JSON verdict to the verdict file named below, and nothing else there:',
  '  {"verdict":"pass"|"fail","findings":[{"file":"<path>","line":<n>,"claim":"<what is wrong>","evidence":"<what shows it>"}]}',
  'Use "line":<n> for a line, and 0 for the file as a whole.',
  'A fail lists at least one defect. A pass lists, in the same shape, what you checked and found sound.',
  'If you cannot write files, make your final answer the JSON verdict alone; the command that runs you writes it there.',
  'change no file: do not edit, commit, push, or write to the tracker. The worktree is checked after you exit, and any change discards your verdict.',
];

function slot(state, repo) {
  state.review = state.review || {};
  const rs = state.review[repo] || { inFlight: [], failed: {} };
  rs.inFlight = rs.inFlight || [];
  rs.failed = rs.failed || {};
  state.review[repo] = rs;
  return rs;
}

// Reviews recorded in flight across every target, without asking anyone.
function inFlightCount(cfg, state) {
  return cfg.targets.reduce((n, t) => n + ((state.review && state.review[t.repo] && state.review[t.repo].inFlight) || []).length, 0);
}

function runName(repo, pr, reviewer, sha) { return `${String(repo).split('/').pop()}-${pr}-${reviewer}-${short(sha)}`; }

// The worktree's HEAD and porcelain status, or { ok:false } when it is gone.
function worktreeState(cfg, wt) {
  if (!fs.existsSync(wt)) return { ok: false, error: `${wt} is gone` };
  const h = run(cfg.bins.git, ['-C', wt, 'rev-parse', 'HEAD'], { timeoutMs: 30000 });
  const s = run(cfg.bins.git, ['-C', wt, 'status', '--porcelain'], { timeoutMs: 60000 });
  if (h.status !== 0 || s.status !== 0) return { ok: false, error: (h.status !== 0 ? h : s).error || (h.status !== 0 ? h : s).stderr.trim() };
  return { ok: true, head: h.stdout.trim(), status: s.stdout };
}

function removeWorktree(cfg, target, wt) {
  run(cfg.bins.git, ['-C', target.localPath, 'worktree', 'remove', '--force', wt], { timeoutMs: 60000 });
  fs.rmSync(wt, { recursive: true, force: true });
  run(cfg.bins.git, ['-C', target.localPath, 'worktree', 'prune'], { timeoutMs: 60000 });
}

// prepare -> { ok, worktree, before } | { ok:false, error }
// A fresh worktree detached at sha: a leftover one of the same name is removed first.
function prepare(cfg, target, wt, sha) {
  const g = args => run(cfg.bins.git, ['-C', target.localPath, ...args], { timeoutMs: 120000 });
  const why = r => r.error || r.stderr.trim() || `exit ${r.status}`;
  if (!fs.existsSync(target.localPath)) return { ok: false, error: `no clone at ${target.localPath}` };
  const f = g(['fetch', 'origin', '--prune']);
  if (f.status !== 0) return { ok: false, error: `git fetch origin in ${target.localPath}: ${why(f)}` };
  if (g(['cat-file', '-e', `${sha}^{commit}`]).status !== 0) {
    const s = g(['fetch', 'origin', sha]);
    if (s.status !== 0 || g(['cat-file', '-e', `${sha}^{commit}`]).status !== 0) return { ok: false, error: `the PR head ${sha} is not in ${target.localPath} after a fetch: ${why(s)}` };
  }
  if (fs.existsSync(wt)) removeWorktree(cfg, target, wt);
  fs.mkdirSync(path.dirname(wt), { recursive: true });
  const w = g(['worktree', 'add', '--detach', wt, sha]);
  if (w.status !== 0) return { ok: false, error: `git worktree add --detach ${wt} ${sha}: ${why(w)}` };
  const before = worktreeState(cfg, wt);
  if (!before.ok) return { ok: false, error: before.error };
  if (before.head !== sha) return { ok: false, error: `${wt} is at ${before.head}, not the PR head ${sha}` };
  return { ok: true, worktree: wt, before: { head: before.head, status: before.status } };
}

// The checks of the standards manifest on the base ref, as the worker was
// given them. -> { ok, checks } (null when standards is "off") | { ok:false, error }
function manifestChecks(cfg, target) {
  if (target.standards === 'off') return { ok: true, checks: null };
  const ref = baseRef(target);
  const rel = path.posix.normalize(target.standards.manifest);
  const g = args => run(cfg.bins.git, ['-C', target.localPath, ...args], { timeoutMs: 60000 });
  const why = r => r.error || r.stderr.trim() || `exit ${r.status}`;
  const ls = g(['ls-tree', '-r', '-z', '--name-only', ref]);
  if (ls.status !== 0) return { ok: false, error: `git ls-tree ${ref} in ${target.localPath}: ${why(ls)}` };
  const files = ls.stdout.split('\0').filter(Boolean);
  if (!files.includes(rel)) return { ok: false, error: `${target.repo} has no ${rel} on ${ref}` };
  const show = g(['show', `${ref}:${rel}`]);
  if (show.status !== 0) return { ok: false, error: `git show ${ref}:${rel}: ${why(show)}` };
  const v = require(path.join(cfg.scriptsDir, 'check-standards.js')).validateStandards({ text: show.stdout, files });
  if (!v.ok) return { ok: false, error: `${rel} on ${ref} is not a valid standards manifest: ${v.defects.join('; ')}` };
  return { ok: true, checks: v.manifest.checks };
}

function buildPrompt({ target, p, iss, reviewer, checks, diff, out }) {
  const lines = [
    `# Review of ${target.repo} PR #${p.number} at ${p.headRefOid}`,
    '',
    `You are reviewer ${reviewer.name}. This worktree is detached at the PR head.`,
    '',
    '## Brief',
    '',
    ...BRIEF,
    '',
    `Verdict file: ${out}`,
    '',
    `## Package issue #${iss.number}: ${iss.title}`,
    '',
    String(iss.body || ''),
    '',
    `## Checks (${target.standards === 'off' ? 'standards off' : target.standards.manifest})`,
    '',
    ...(checks ? checks.map(c => `- ${c.name}: ${c.command}`) : ['This target publishes no standards manifest to fleet; there are no declared checks.']),
    '',
    `## Diff: git diff ${baseRef(target)}...HEAD`,
    '',
    'Everything below this line is the diff.',
    '',
    diff,
  ];
  return lines.join('\n');
}

// parseVerdict(text) -> { ok, verdict, findings } | { ok:false, error }
// A reviewer may put prose around its JSON. Whole text first; else one candidate:
// the last fenced block (```json or bare ```), else the first "{" to the last "}".
function jsonCandidate(text) {
  const s = String(text);
  let fenced = null;
  for (const m of s.matchAll(/```(?:json)?[ \t]*\r?\n([\s\S]*?)```/g)) fenced = m[1];
  if (fenced !== null) return fenced;
  const a = s.indexOf('{');
  const b = s.lastIndexOf('}');
  return a !== -1 && b > a ? s.slice(a, b + 1) : null;
}

function parseVerdict(text) {
  let v;
  try { v = JSON.parse(text); } catch (e) {
    const cand = jsonCandidate(text);
    if (cand === null) return { ok: false, error: `not JSON (${e.message}; no JSON candidate found)` };
    try { v = JSON.parse(cand); } catch (e2) { return { ok: false, error: `not JSON (${e2.message})` }; }
  }
  if (!v || typeof v !== 'object' || Array.isArray(v)) return { ok: false, error: 'not a JSON object' };
  if (v.verdict !== 'pass' && v.verdict !== 'fail') return { ok: false, error: `verdict ${JSON.stringify(v.verdict)} is not "pass" or "fail"` };
  if (!Array.isArray(v.findings)) return { ok: false, error: 'findings is not an array' };
  for (const [i, f] of v.findings.entries()) {
    const ok = f && typeof f === 'object' && typeof f.file === 'string' && f.file.trim() && Number.isInteger(f.line) && f.line >= 0
      && typeof f.claim === 'string' && f.claim.trim() && typeof f.evidence === 'string' && f.evidence.trim();
    if (!ok) return { ok: false, error: `findings[${i}] is not {file, line >= 0, claim, evidence}, each non-empty` };
  }
  if (v.verdict === 'fail' && !v.findings.length) return { ok: false, error: 'a fail with no findings' };
  return { ok: true, verdict: v.verdict, findings: v.findings };
}

// One finding per entry, every line starting "- " or "  ", so a finding can
// never forge a REVIEWED or VERIFIED stamp line.
function findingLines(findings) {
  if (!findings.length) return '- (no findings listed)';
  return findings.map(f => `- ${oneLine(f.file)}${f.line === 0 ? '' : `:${f.line}`} — ${oneLine(f.claim)}\n  evidence: ${clip(f.evidence, 1000)}`).join('\n');
}

// stage(ctx) -> { requests: [{ session, next: 'review-failed', reason }], reviewing }
// ctx: { cfg, state, apply, tracker, pulls, pullsFailed (Set of repos), sync, issues, at, alarm, r, now? }
// Mutates state.review and r (review notes, movement).
function stage({ cfg, state, apply, tracker, pulls, pullsFailed = new Set(), sync, issues, at, alarm, r, now = Date.now() }) {
  const out = { requests: [], reviewing: 0 };
  if (!cfg.reviewers.length && inFlightCount(cfg, state) === 0) return out;
  const { currentReviews } = require(path.join(cfg.scriptsDir, 'stamp.js'));
  const synced = (sync.state && sync.state.issues) || [];
  const awaiting = new Set((sync.rows || []).filter(x => x.to === 'cell:awaiting-reviewer').map(x => x.number));

  for (const t of cfg.targets) {
    const rs = slot(state, t.repo);
    const note = (pr, action, detail) => r.review.push({ target: t.repo, pr, action, detail });
    const prOf = n => pulls.find(p => p.repo === t.repo && p.number === n) || null;
    const pkgOf = n => synced.find(i => i.pr && i.pr.number === n && i.repo === t.repo) || null;

    // Without this target's PR list a finished run cannot be judged. The
    // records are kept for next cycle.
    if (pullsFailed.has(t.repo)) {
      out.reviewing += rs.inFlight.length;
      if (rs.inFlight.length) note(rs.inFlight.map(f => f.pr).join(','), 'skipped', 'the PR list for this target failed (pulls-failed)');
      continue;
    }

    const failAt = (f, kind, reason) => {
      if (!apply) return;
      rs.failed[f.pr] = { ...(rs.failed[f.pr] || {}), [f.reviewer]: { headSha: f.headSha, kind, reason, at } };
    };
    const done = f => { if (apply) removeWorktree(cfg, t, f.worktree); };

    // The runs in flight: running, leave it; over its time, stop it; exited, act.
    // A PR acted on here is not launched on again this cycle: the sync's
    // comments predate a stamp or a failure posted now.
    const keep = [];
    const acted = new Set();
    for (const f of rs.inFlight) {
      const who = `${f.reviewer} on ${t.repo}#${f.pr}`;
      acted.add(f.pr);
      const exited = fs.existsSync(f.exitPath);
      if (!exited && isAlive(f.pid)) {
        const minutes = (now - Date.parse(f.startedAt)) / 60000;
        if (minutes <= f.timeoutMinutes) { keep.push(f); out.reviewing += 1; note(f.pr, 'running', `${f.reviewer} at ${short(f.headSha)}`); continue; }
        if (!apply) { keep.push(f); out.reviewing += 1; note(f.pr, 'would-time-out', `${f.reviewer} has run ${Math.round(minutes)} of ${f.timeoutMinutes} minutes`); continue; }
        signal(f.pid, 'SIGKILL');
        alarm('review-timeout', `${who} ran past ${f.timeoutMinutes} minutes at ${short(f.headSha)} and was stopped; nothing is stamped`, f.issue);
        failAt(f, 'timeout', `timed out after ${f.timeoutMinutes} minutes`);
        note(f.pr, 'timed-out', f.reviewer);
        done(f);
        continue;
      }

      // Read-only, checked for any command: a moved HEAD or any change in the
      // worktree discards the verdict.
      const after = worktreeState(cfg, f.worktree);
      if (!after.ok || after.head !== f.before.head || after.status !== f.before.status) {
        const what = !after.ok ? after.error : after.head !== f.before.head ? `HEAD moved from ${short(f.before.head)} to ${short(after.head)}` : `the worktree changed: ${oneLine(after.status)}`;
        alarm('review-wrote', `${who}: ${what}; the verdict is discarded and nothing is stamped`, f.issue);
        failAt(f, 'wrote', what);
        note(f.pr, apply ? 'wrote' : 'would-discard', `${f.reviewer}: ${what}`);
        if (!apply) keep.push(f);
        done(f);
        continue;
      }

      const p = prOf(f.pr);
      // A PR missing from the list (one past the page limit) is not a closed one.
      if (!p) { keep.push(f); alarm('review-pr-missing', `${who} finished, but PR #${f.pr} is not in the PR list of ${t.repo}; the record is kept`, f.issue); continue; }
      if (!isOpen(p) || p.headRefOid !== f.headSha) {
        const why = !isOpen(p) ? `PR #${f.pr} is ${p.state}, not open` : `PR #${f.pr} head moved from ${short(f.headSha)} to ${short(p.headRefOid)}`;
        alarm('review-stale', `${who}: ${why}; the verdict is discarded and nothing is stamped`, f.issue);
        note(f.pr, apply ? 'stale' : 'would-discard', why);
        if (!apply) keep.push(f);
        done(f);
        continue;
      }

      let text = null;
      try { text = fs.readFileSync(f.out, 'utf8'); } catch { /* missing */ }
      const v = text === null ? { ok: false, error: `no verdict at ${f.out}` } : parseVerdict(text);
      if (!v.ok) {
        alarm('review-invalid', `${who} at ${short(f.headSha)}: ${v.error}; nothing is stamped, and ${f.reviewer} is not run again at this head`, f.issue);
        failAt(f, 'invalid', v.error);
        note(f.pr, apply ? 'invalid' : 'would-discard', `${f.reviewer}: ${v.error}`);
        if (!apply) keep.push(f);
        done(f);
        continue;
      }

      const si = pkgOf(f.pr);
      const id = f.package || (si && scope.packageId(si.title)) || `PR #${f.pr}`;
      if (v.verdict === 'pass') {
        if (!apply) { keep.push(f); note(f.pr, 'would-stamp', `REVIEWED: ${f.reviewer} @ ${short(f.headSha)}`); continue; }
        const c = tracker.prComment(t.repo, f.pr, `REVIEWED: ${f.reviewer} @ ${f.headSha}\n\nFindings checked:\n${findingLines(v.findings)}`);
        if (!c.ok) { keep.push(f); alarm('review-write-failed', `stamp on ${t.repo}#${f.pr} failed: ${c.error}; the verdict is read again next cycle`, f.issue); continue; }
        r.movement.push({ package: id, issue: f.issue, artifact: { type: 'reviewed', ref: f.pr, detail: `${f.reviewer} @ ${short(f.headSha)}` } });
        note(f.pr, 'reviewed', `${f.reviewer} at ${short(f.headSha)}`);
        done(f);
        continue;
      }

      const reason = `review-failed: ${oneLine(v.findings[0].claim)}`;
      if (!apply) { keep.push(f); note(f.pr, 'would-fail', reason); continue; }
      const c = tracker.prComment(t.repo, f.pr, `Review by ${f.reviewer} failed at ${f.headSha}.\n\nFindings:\n${findingLines(v.findings)}`);
      if (!c.ok) { keep.push(f); alarm('review-write-failed', `failure comment on ${t.repo}#${f.pr} failed: ${c.error}; the verdict is read again next cycle`, f.issue); continue; }
      failAt(f, 'failed', reason);
      note(f.pr, 'failed', `${f.reviewer}: ${reason}`);
      done(f);
      // The worker that opened the PR is sent back at the same tier, through
      // the cycle's verify-failed path; it counts toward maxEscalations.
      const s = f.issue ? state.sessions[f.issue] : null;
      if (!s) { alarm('review-redispatch-failed', `${id}: no session record on this machine, so nobody is re-dispatched; the findings are on the PR`, f.issue); continue; }
      if (s.status !== 'closed') { alarm('review-redispatch-failed', `${id}: session is ${s.status}, not closed, so it is not re-dispatched; the findings are on the PR`, f.issue); continue; }
      out.requests.push({ session: s, next: 'review-failed', reason });
    }
    rs.inFlight = keep;

    // The next reviewer for each waiting PR: first in config order with no
    // current stamp at the head and no failure there. One per PR in flight.
    if (!cfg.reviewers.length) continue;
    let checks = null;
    for (const si of synced) {
      if (!awaiting.has(si.number) || !si.pr || si.repo !== t.repo) continue;
      const p = prOf(si.pr.number);
      if (!isOpen(p) || acted.has(p.number)) continue;
      const head = p.headRefOid;
      const stamped = new Set(currentReviews({ headSha: head, comments: si.pr.comments || [] }).map(x => x.reviewer));
      const failed = rs.failed[p.number] || {};
      const rv = cfg.reviewers.find(x => !stamped.has(x.name) && !(failed[x.name] && failed[x.name].headSha === head));
      const id = scope.packageId(si.title) || `#${si.number}`;
      if (!rv) { note(p.number, 'held', `no reviewer left at ${short(head)}: each has stamped or failed there`); continue; }
      if (!apply) { note(p.number, 'would-launch', `${rv.name} for ${id} at ${short(head)}`); continue; }

      const iss = issues.find(i => i.number === si.number);
      if (!iss) { alarm('review-launch-failed', `${t.repo}#${p.number}: package issue #${si.number} is not in the issue list`, si.number); continue; }
      if (checks === null) {
        const m = manifestChecks(cfg, t);
        if (!m.ok) { alarm('review-launch-failed', `${t.repo}: ${m.error}; no reviewer is launched`, si.number); break; }
        checks = m;
      }
      const name = runName(t.repo, p.number, rv.name, head);
      const dir = path.join(cfg.stateDir, 'review', name);
      const wt = path.join(cfg.worktreesDir, '.review', name);
      fs.rmSync(dir, { recursive: true, force: true });
      fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
      const prep = prepare(cfg, t, wt, head);
      if (!prep.ok) { alarm('review-launch-failed', `${rv.name} on ${t.repo}#${p.number}: ${prep.error}`, si.number); continue; }
      const d = run(cfg.bins.git, ['-C', wt, 'diff', `${baseRef(t)}...HEAD`], { timeoutMs: 120000 });
      if (d.status !== 0) { alarm('review-launch-failed', `${rv.name} on ${t.repo}#${p.number}: git diff ${baseRef(t)}...HEAD: ${d.error || d.stderr.trim()}`, si.number); removeWorktree(cfg, t, wt); continue; }
      const promptPath = path.join(dir, 'prompt.md');
      const outPath = path.join(dir, 'verdict.json');
      fs.writeFileSync(promptPath, buildPrompt({ target: t, p, iss, reviewer: rv, checks: checks.checks, diff: d.stdout, out: outPath }), { mode: 0o600 });
      const sub = a => a.split('{prompt}').join(promptPath).split('{worktree}').join(wt).split('{out}').join(outPath);
      const argv = rv.argv.map(sub);
      const env = { ...process.env, FLEET_REVIEWER: rv.name, FLEET_REVIEW_REPO: t.repo, FLEET_REVIEW_PR: String(p.number) };
      delete env.CLAUDECODE;
      const exitPath = path.join(dir, 'exit');
      const { pid } = spawnDetached(argv[0], argv.slice(1), { cwd: wt, env, logPath: path.join(dir, 'log'), exitPath });
      rs.inFlight.push({
        pr: p.number, reviewer: rv.name, headSha: head, issue: si.number, pid, startedAt: new Date(now).toISOString(),
        package: id, timeoutMinutes: rv.timeoutMinutes, worktree: wt, out: outPath, exitPath, before: prep.before,
      });
      out.reviewing += 1;
      note(p.number, 'launched', `${rv.name} for ${id} at ${short(head)}`);
    }
  }
  return out;
}

module.exports = { stage, inFlightCount, parseVerdict, findingLines, buildPrompt, BRIEF };
