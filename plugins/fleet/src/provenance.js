'use strict';

/*
 * Label provenance (X0.3): who applied a package's coordinator labels.
 *
 * Fleet acts on agent-ready, cell:<x> and worker:<x>. Only a coordinator
 * (cfg.coordinators) may apply them; one applied by any other account (an
 * external worker's session labeling packages for itself, #240) is flagged,
 * and the cycle holds the package. The latest `labeled` event of a label is
 * the one judged, so a coordinator re-applying it clears the flag.
 *
 * Fail closed: a timeline that cannot be read is an error for that issue, and
 * the caller holds it as it holds a flagged one. A label on the issue with no
 * `labeled` event in its timeline, or one from a deleted account, has no
 * coordinator behind it and is flagged too.
 *
 * Judges only the open issues it is given, and only when cfg.coordinators is
 * non-empty: with the check off it reads nothing.
 */

const scope = require('./scope');

const JUDGED = l => l === 'agent-ready' || /^(cell|worker):./.test(l);
const labelsOf = i => (i.labels || []).map(l => (typeof l === 'string' ? l : l.name));

// foreign(cfg, issues, tracker) -> { flagged: [{number, id, label, actor}], errors: [{number, id, error}] }
// One timeline read per open issue that carries a judged label.
function foreign(cfg, issues, tracker) {
  const out = { flagged: [], errors: [] };
  const trusted = new Set(cfg.coordinators || []);
  if (!trusted.size) return out;
  for (const i of issues) {
    if (String(i.state || 'OPEN').toUpperCase() !== 'OPEN') continue;
    const judged = labelsOf(i).filter(JUDGED);
    if (!judged.length) continue;
    const id = scope.packageId(i.title) || 'package';
    const t = tracker.labelActors(cfg.repo, i.number);
    if (!t.ok) { out.errors.push({ number: i.number, id, error: t.error }); continue; }
    for (const label of judged) {
      const actor = Object.prototype.hasOwnProperty.call(t.actors, label) ? t.actors[label] : null;
      if (actor === null || !trusted.has(actor)) out.flagged.push({ number: i.number, id, label, actor });
    }
  }
  return out;
}

module.exports = { foreign, JUDGED };
