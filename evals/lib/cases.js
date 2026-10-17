'use strict';
// Load and validate eval cases. The format is documented in evals/schema.json.

const fs = require('fs');
const path = require('path');

const KINDS = ['tests', 'lint', 'policy'];
const ID = /^[A-Za-z0-9._-]+$/;

function validateCase(c, file) {
  const bad = msg => { throw new Error(`case ${file}: ${msg}`); };
  if (!c || typeof c !== 'object' || Array.isArray(c)) bad('must be a JSON object');
  if (typeof c.id !== 'string' || !ID.test(c.id)) bad('id must match [A-Za-z0-9._-]+');
  if (typeof c.prompt !== 'string' || !c.prompt.trim()) bad('prompt must be a non-empty string');
  if (!Array.isArray(c.checks)) bad('checks must be an array');
  for (const k of c.checks) {
    if (!k || typeof k.name !== 'string' || !k.name) bad('every check needs a name');
    if (!KINDS.includes(k.kind)) bad(`check "${k.name}": kind must be one of ${KINDS.join(', ')}`);
    const hasCmd = typeof k.command === 'string' && k.command;
    const hasRes = k.resultMatches !== undefined || k.resultNotMatches !== undefined;
    if (!hasCmd && !hasRes) bad(`check "${k.name}": needs command, resultMatches or resultNotMatches`);
    for (const f of ['resultMatches', 'resultNotMatches']) {
      if (k[f] === undefined) continue;
      try { new RegExp(k[f]); } catch (e) { bad(`check "${k.name}": ${f} is not a valid regex`); }
    }
  }
  if (c.timeoutSeconds !== undefined && !(Number.isFinite(c.timeoutSeconds) && c.timeoutSeconds > 0)) bad('timeoutSeconds must be a positive number');
  return c;
}

// A directory with no *.json cases is an error, not an empty pass.
function loadCases(dir) {
  let names;
  try { names = fs.readdirSync(dir).filter(n => n.endsWith('.json')).sort(); }
  catch (e) { throw new Error(`cannot read cases directory ${dir}: ${e.message}`); }
  if (names.length === 0) throw new Error(`no cases found in ${dir}: the glob matched nothing`);
  const cases = names.map(n => {
    const file = path.join(dir, n);
    let parsed;
    try { parsed = JSON.parse(fs.readFileSync(file, 'utf8')); }
    catch (e) { throw new Error(`case ${file}: invalid JSON: ${e.message}`); }
    return validateCase(parsed, file);
  });
  const seen = new Set();
  for (const c of cases) {
    if (seen.has(c.id)) throw new Error(`duplicate case id ${c.id}`);
    seen.add(c.id);
  }
  return cases;
}

module.exports = { loadCases, validateCase, KINDS };
