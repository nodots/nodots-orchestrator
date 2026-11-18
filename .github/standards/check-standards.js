#!/usr/bin/env node
'use strict';

/*
 * check-standards.js — validate a repo's standards manifest (.claude/standards.json).
 *
 * The contract, and every rule enforced here, is references/standards.md. This
 * file is the one validator; the launcher, the init command and the preamble
 * hook reuse it rather than each accepting a different manifest.
 *
 * No dependencies, like the hooks. The glob matcher lives here on purpose: it
 * is not imported from the hooks, so the hooks can change without changing
 * what a valid manifest is.
 *
 * Module:
 *   validateStandards({ text, files, settings }) -> { ok, manifest, defects, warnings }
 *     Pure. `text` is the manifest's contents, `files` the repo's tracked file
 *     list. `settings` is the text of the tracked .claude/settings.json, or null
 *     when that file is not tracked; each declared plugin must be enabled there.
 *     `settings` undefined skips that check. Each defect is
 *     "<location>: <message>"; each warning is "<doc>: rule has no check".
 *   validateFile(repoRoot, manifestPath = '.claude/standards.json')
 *     Reads the manifest (tracked or not) and takes `files` from
 *     `git -C <repoRoot> ls-files`. When `plugins[]` is non-empty, reads
 *     .claude/settings.json if it is tracked and passes null if not. Same result
 *     shape, plus `path`.
 *   validateReview(review) -> defects
 *     The `review` key alone, for a reader that has no tracked file list.
 *
 * CLI:
 *   node check-standards.js [--root <dir>] [--json] [<manifest>]
 *   exit 0  valid; warnings, if any, on stderr; --json prints the normalized
 *           manifest on stdout
 *   exit 2  invalid, missing or unparsable; one line per defect on stderr,
 *           shaped "standards: <path>: <defect>"
 */

const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');

const DEFAULT_MANIFEST = '.claude/standards.json';
const SETTINGS = '.claude/settings.json';
const CHECK_NAME = /^[a-z][a-z0-9-]*$/;
const PLUGIN_FIELD = /^[A-Za-z0-9_.-]+$/;

const TOP_KEYS = ['version', 'checks', 'rules', 'preamble', 'plugins', 'review'];
const CHECK_KEYS = ['name', 'command'];
const RULE_KEYS = ['doc', 'paths', 'check'];
const PLUGIN_KEYS = ['name', 'marketplace'];
const REVIEW_KEYS = ['passes'];

const isObject = (v) => v !== null && typeof v === 'object' && !Array.isArray(v);
const has = (o, k) => Object.prototype.hasOwnProperty.call(o, k);
const show = (v) => JSON.stringify(v);

// --- glob matching ------------------------------------------------------------
// `**` is a whole segment matching any number of segments, including none.
// `*` matches any run of characters within one segment. Every other character
// is literal. Matched against the tracked file list only.

function segmentRegex(seg) {
  const body = seg.split('*').map((s) => s.replace(/[.+?^${}()|[\]\\]/g, '\\$&')).join('[^/]*');
  return new RegExp(`^${body}$`);
}

function matchSegments(pat, pi, parts, fi) {
  if (pi === pat.length) return fi === parts.length;
  if (pat[pi] === '**') {
    for (let k = fi; k <= parts.length; k++) {
      if (matchSegments(pat, pi + 1, parts, k)) return true;
    }
    return false;
  }
  if (fi === parts.length) return false;
  if (!segmentRegex(pat[pi]).test(parts[fi])) return false;
  return matchSegments(pat, pi + 1, parts, fi + 1);
}

function globMatches(glob, file) {
  return matchSegments(glob.split('/'), 0, file.split('/'), 0);
}

// --- validation ---------------------------------------------------------------

function unknownKeys(obj, allowed, where, defects) {
  for (const k of Object.keys(obj)) {
    if (!allowed.includes(k)) defects.push(`${where ? `${where}.` : ''}${k}: unknown key`);
  }
}

// The review policy: how many independent reviews a PR needs. null is the same
// as absent. Exported so sync-cells.sh judges a policy by the same rules without
// the tracked file list a full manifest needs.
function validateReview(review) {
  const defects = [];
  if (review === null) return defects;
  if (!isObject(review)) {
    defects.push('review: must be null or an object with one integer key, passes');
    return defects;
  }
  unknownKeys(review, REVIEW_KEYS, 'review', defects);
  if (!Number.isInteger(review.passes)) defects.push('review.passes: must be an integer >= 1');
  else if (review.passes < 1) defects.push(`review.passes: ${show(review.passes)} must be >= 1`);
  return defects;
}

// Each declared plugin must be enabled in the repo's tracked .claude/settings.json:
// the key "<name>@<marketplace>" present in enabledPlugins and exactly true, the
// same test as the fleet launcher's pluginEnabled. `declared` holds only items
// whose name and marketplace are well formed; a malformed one already has its
// defect. `settings` is the file's text, or null when it is not tracked.
function enablementDefects(declared, settings) {
  if (declared.length === 0) return [];
  let s = null;
  if (settings !== null) {
    try {
      s = JSON.parse(settings);
    } catch (e) {
      return [`${SETTINGS}: not valid JSON: ${e.message}`];
    }
    if (!isObject(s)) return [`${SETTINGS}: not a JSON object`];
  }
  const ep = s && isObject(s.enabledPlugins) ? s.enabledPlugins : null;
  return declared
    .filter(({ key }) => !(ep && has(ep, key) && ep[key] === true))
    .map(({ at, key }) => `${at}: ${key} is not enabled in ${SETTINGS}`);
}

function validateStandards({ text, files, settings }) {
  const defects = [];
  const warnings = [];
  const tracked = new Set(files);

  let m;
  try {
    m = JSON.parse(text);
  } catch (e) {
    return { ok: false, manifest: null, defects: [`not valid JSON: ${e.message}`], warnings };
  }
  if (!isObject(m)) {
    return { ok: false, manifest: null, defects: ['manifest: must be a JSON object'], warnings };
  }

  unknownKeys(m, TOP_KEYS, '', defects);

  if (m.version !== 1) defects.push('version: must be the integer 1');

  const names = new Set();
  if (!Array.isArray(m.checks) || m.checks.length === 0) {
    defects.push('checks: must be a non-empty array');
  } else {
    m.checks.forEach((c, i) => {
      const at = `checks[${i}]`;
      if (!isObject(c)) { defects.push(`${at}: must be an object`); return; }
      unknownKeys(c, CHECK_KEYS, at, defects);
      if (typeof c.name !== 'string') {
        defects.push(`${at}.name: must be a string matching ${CHECK_NAME.source}`);
      } else if (!CHECK_NAME.test(c.name)) {
        defects.push(`${at}.name: ${show(c.name)} must match ${CHECK_NAME.source}`);
      } else if (names.has(c.name)) {
        defects.push(`${at}.name: ${show(c.name)} is not unique`);
      } else {
        names.add(c.name);
      }
      if (typeof c.command !== 'string' || c.command.length === 0) {
        defects.push(`${at}.command: must be a non-empty string`);
      }
    });
  }

  if (!Array.isArray(m.rules)) {
    defects.push('rules: must be an array');
  } else {
    m.rules.forEach((r, i) => {
      const at = `rules[${i}]`;
      if (!isObject(r)) { defects.push(`${at}: must be an object`); return; }
      unknownKeys(r, RULE_KEYS, at, defects);

      if (typeof r.doc !== 'string') {
        defects.push(`${at}.doc: must be a string`);
      } else {
        const hash = r.doc.indexOf('#');
        const file = hash === -1 ? r.doc : r.doc.slice(0, hash);
        if (!tracked.has(file)) defects.push(`${at}.doc: ${show(file)} is not a tracked file`);
      }

      if (has(r, 'paths') && r.paths !== null) {
        if (!Array.isArray(r.paths) || r.paths.length === 0) {
          defects.push(`${at}.paths: must be a non-empty array of globs`);
        } else {
          r.paths.forEach((g, j) => {
            if (typeof g !== 'string' || g.length === 0) {
              defects.push(`${at}.paths[${j}]: must be a non-empty glob`);
            } else if (!files.some((f) => globMatches(g, f))) {
              defects.push(`${at}.paths[${j}]: ${show(g)} matches no tracked file`);
            }
          });
        }
      }

      if (!has(r, 'check') || (r.check !== null && typeof r.check !== 'string')) {
        defects.push(`${at}.check: must be null or the name of a check`);
      } else if (r.check === null) {
        warnings.push(`${typeof r.doc === 'string' ? r.doc : at}: rule has no check`);
      } else if (!names.has(r.check)) {
        defects.push(`${at}.check: ${show(r.check)} names no check`);
      }
    });
  }

  if (has(m, 'preamble') && m.preamble !== null) {
    if (typeof m.preamble !== 'string') {
      defects.push('preamble: must be a string');
    } else if (!tracked.has(m.preamble)) {
      defects.push(`preamble: ${show(m.preamble)} is not a tracked file`);
    }
  }

  if (has(m, 'plugins')) {
    if (!Array.isArray(m.plugins)) {
      defects.push('plugins: must be an array');
    } else {
      const declared = [];
      m.plugins.forEach((p, i) => {
        const at = `plugins[${i}]`;
        if (!isObject(p)) { defects.push(`${at}: must be an object`); return; }
        unknownKeys(p, PLUGIN_KEYS, at, defects);
        let named = true;
        for (const k of PLUGIN_KEYS) {
          if (typeof p[k] !== 'string') {
            defects.push(`${at}.${k}: must be a string matching ${PLUGIN_FIELD.source}`);
            named = false;
          } else if (!PLUGIN_FIELD.test(p[k])) {
            defects.push(`${at}.${k}: ${show(p[k])} must match ${PLUGIN_FIELD.source}`);
            named = false;
          }
        }
        if (named) declared.push({ at, key: `${p.name}@${p.marketplace}` });
      });
      if (m.plugins.length > 0 && settings !== undefined) {
        defects.push(...enablementDefects(declared, settings));
      }
    }
  }

  if (has(m, 'review')) defects.push(...validateReview(m.review));

  if (defects.length > 0) return { ok: false, manifest: m, defects, warnings };
  return { ok: true, manifest: normalize(m), defects, warnings };
}

// Canonical key order; an absent preamble is null, absent plugins [], an
// absent rule `paths` null, an absent review null. Only called on a manifest
// with no defects.
function normalize(m) {
  return {
    version: m.version,
    checks: m.checks.map((c) => ({ name: c.name, command: c.command })),
    rules: m.rules.map((r) => ({
      doc: r.doc,
      paths: has(r, 'paths') && r.paths !== null ? r.paths.slice() : null,
      check: r.check,
    })),
    preamble: has(m, 'preamble') ? m.preamble : null,
    plugins: has(m, 'plugins') ? m.plugins.map((p) => ({ name: p.name, marketplace: p.marketplace })) : [],
    review: has(m, 'review') && m.review !== null ? { passes: m.review.passes } : null,
  };
}

function validateFile(repoRoot, manifestPath = DEFAULT_MANIFEST) {
  const fail = (defect) => ({ ok: false, manifest: null, defects: [defect], warnings: [], path: manifestPath });

  let text;
  try {
    text = fs.readFileSync(path.resolve(repoRoot, manifestPath), 'utf8');
  } catch (e) {
    return fail(e.code === 'ENOENT' ? 'file not found' : `cannot read: ${e.code || e.message}`);
  }

  let files;
  try {
    const out = execFileSync('git', ['-C', repoRoot, 'ls-files', '-z'], {
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    files = out.split('\0').filter(Boolean);
  } catch (e) {
    return fail(`cannot list tracked files: git ls-files failed in ${repoRoot}`);
  }

  // The settings file is read only when the manifest declares plugins, and only
  // when it is tracked: an untracked one is passed as null, the same as absent.
  let settings;
  let m = null;
  try { m = JSON.parse(text); } catch (e) { /* validateStandards names it */ }
  if (isObject(m) && Array.isArray(m.plugins) && m.plugins.length > 0) {
    settings = null;
    if (files.includes(SETTINGS)) {
      try {
        settings = fs.readFileSync(path.resolve(repoRoot, SETTINGS), 'utf8');
      } catch (e) {
        return fail(`${SETTINGS}: cannot read: ${e.code || e.message}`);
      }
    }
  }

  return { ...validateStandards({ text, files, settings }), path: manifestPath };
}

// --- CLI ----------------------------------------------------------------------

function main(argv) {
  let root = process.cwd();
  let json = false;
  let manifest = DEFAULT_MANIFEST;
  let positional = 0;
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--json') json = true;
    else if (a === '--root' && i + 1 < argv.length) root = argv[++i];
    else if (!a.startsWith('--') && positional === 0) { manifest = a; positional++; }
    else {
      process.stderr.write('standards: usage: check-standards.js [--root <dir>] [--json] [<manifest>]\n');
      return 2;
    }
  }

  const r = validateFile(root, manifest);
  for (const w of r.warnings) process.stderr.write(`standards: ${w}\n`);
  if (!r.ok) {
    for (const d of r.defects) process.stderr.write(`standards: ${manifest}: ${d}\n`);
    return 2;
  }
  if (json) process.stdout.write(`${JSON.stringify(r.manifest, null, 2)}\n`);
  return 0;
}

module.exports = { validateStandards, validateFile, validateReview };

if (require.main === module) process.exitCode = main(process.argv.slice(2));
