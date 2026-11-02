'use strict';

/*
 * The cycle report: the one of three answers the cycle contract requires
 * (coordination.md §The cycle contract), as JSON for machines and one block
 * of text for the epic's progress log. Posting is idempotent: the comment
 * carries a marker with the cycle id, and a repost checks for it first.
 */

const MARKER = id => `<!-- fleet-cycle:${id} -->`;

function summarize(r) {
  const c = r.counts || {};
  const head = r.outcome === 'movement'
    ? `MOVEMENT ${r.movement.map(m => `${m.package} ${m.artifact.type}:${m.artifact.ref}`).join(', ')}`
    : r.outcome === 'exhaustion'
      ? `EXHAUSTION open=${c.open} queued=${c.queued} active=${c.active} review=${c.awaitingReview} blocked=${c.blocked} merged=${c.merged} live=${c.live} free=${c.wipFree}`
      : `ALARM ${r.alarms.map(a => a.code).join(', ') || 'see report'}`;
  return `fleet cycle ${r.cycleId}: ${head}; streak=${r.streak}${r.latched ? ' LATCHED' : ''}`;
}

function render(r) {
  const lines = [MARKER(r.cycleId), `## fleet cycle ${r.cycleId} — ${r.outcome.toUpperCase()}`, '', `_${r.at}_`, ''];
  if (r.movement.length) {
    lines.push('**Movement**');
    for (const m of r.movement) lines.push(`- ${m.package} (#${m.issue}): ${m.artifact.type} ${m.artifact.ref}${m.artifact.detail ? ` — ${m.artifact.detail}` : ''}`);
    lines.push('');
  }
  const c = r.counts;
  lines.push('**Counts** (read live at the end of the cycle)');
  lines.push(`open ${c.open} · queued ${c.queued} · active ${c.active} · awaiting-review ${c.awaitingReview} · blocked ${c.blocked} · merged ${c.merged} · live sessions ${c.live} · WIP free ${c.wipFree}/${c.wipCap}`);
  lines.push('');
  if (r.alarms.length) {
    lines.push('**Alarms**');
    for (const a of r.alarms) lines.push(`- ${a.code}${a.issue ? ` (#${a.issue})` : ''}: ${a.detail}`);
    lines.push('');
  }
  if (r.launched.length) {
    lines.push('**Launched**');
    for (const l of r.launched) lines.push(`- ${l.id} (#${l.issue}) → worker:${l.worker} ${l.mode} tier=${l.tier} attempt=${l.attempt} on ${l.branch}${l.ci && l.ci.gate === 'external' ? ` · CI external: ${l.ci.verifiedBy}` : ''}`);
    lines.push('');
  }
  if (r.reaped.length) {
    lines.push('**Reaped**');
    for (const x of r.reaped) lines.push(`- ${x.id} (#${x.issue}) attempt ${x.attempt}: ${x.outcome} — ${x.detail}`);
    lines.push('');
  }
  if (r.escalations.length) {
    lines.push('**Escalations**');
    for (const e of r.escalations) lines.push(`- ESCALATE ${e.package} n=${e.n} ${e.from}->${e.to} reason=${e.reason}`);
    lines.push('');
  }
  if (r.parked && r.parked.length) {
    lines.push('**Parked (coordinator decision needed)**');
    for (const p of r.parked) lines.push(`- ${p.id} (#${p.issue}): ${p.detail}`);
    lines.push('');
  }
  if (r.promoted && r.promoted.length) lines.push(`**Promoted to cell:queued:** ${r.promoted.map(p => `${p.id} (#${p.number})`).join(', ')}`, '');
  if (r.assigned && r.assigned.length) lines.push(`**Assigned:** ${r.assigned.map(a => `#${a.number}→worker:${a.worker}`).join(', ')}`, '');
  if (r.sync && r.sync.changes && r.sync.changes.length) lines.push(`**Labels derived:** ${r.sync.changes.map(s => `#${s.number} ${s.from || 'none'}→${s.to}`).join(', ')}`, '');
  lines.push(`streak ${r.streak}${r.latched ? ` — LATCHED (${r.latched.reason}); run \`fleet resume --reason ...\` to continue` : ''}`);
  if (r.dryRun) lines.unshift('_dry run: nothing was written_', '');
  return lines.join('\n');
}

// post(tracker, cfg, report) -> { ok, skipped?, error? }
function post(tracker, cfg, report) {
  const existing = tracker.listComments(cfg.repo, cfg.epic);
  if (existing.ok && existing.comments.some(c => String(c.body || '').includes(MARKER(report.cycleId)))) return { ok: true, skipped: true };
  const r = tracker.comment(cfg.repo, cfg.epic, render(report));
  return r.ok ? { ok: true, url: r.url } : { ok: false, error: r.error };
}

module.exports = { render, summarize, post, MARKER };
