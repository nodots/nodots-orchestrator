#!/usr/bin/env node
'use strict';

/*
 * SessionStart hook: the repo's standards reach the session deterministically.
 *
 * A skill is model-invoked and may not load. A rule whose value is that it is
 * never missed needs a path into context that does not depend on the model, so
 * this hook prints the standards the repo names in .claude/standards.json at
 * every session start. The content is the repo's; this hook is the mechanism.
 *
 * Control header
 * --------------
 * Root: $CLAUDE_PROJECT_DIR when set, otherwise the cwd.
 * Default: silent. No <root>/.claude/standards.json, no output, exit 0, so the
 *   plugin can register this hook for every repository.
 * With a manifest: one heading line, one "- <name>: <command>" line per check,
 *   then, when `preamble` names a file, a blank line and that file verbatim.
 * Fail posture: open, and loud. Stdout reaches the model only on exit 0, so
 *   this hook never exits non-zero. An unparsable manifest, a `preamble` file
 *   that does not exist, or any other error prints one stderr line naming this
 *   hook and the problem, nothing on stdout, and exits 0.
 * Residue — what this hook does not judge: whether the manifest is valid
 *   beyond parsing (the validator, check-standards.js, is the launcher's job),
 *   whether the commands run, or whether the preamble says anything useful.
 *
 * Wire it up in .claude/settings.json:
 *   { "hooks": { "SessionStart": [ { "matcher": "", "hooks": [ { "type": "command",
 *       "command": "node .claude/hooks/standards-preamble.js" } ] } ] } }
 */

const fs = require('fs');
const path = require('path');

const HOOK = 'standards-preamble';
const MANIFEST = path.join('.claude', 'standards.json');
const HEADING = '## Repository standards (.claude/standards.json)';

function fail(message) {
  try {
    process.stderr.write(`${HOOK}: ${String(message).replace(/\s*\n\s*/g, ' ')}\n`);
  } catch { /* stderr gone; nothing further this hook can do */ }
  process.exit(0);
}

try {
  const root = process.env.CLAUDE_PROJECT_DIR || process.cwd();
  const manifestPath = path.join(root, MANIFEST);
  if (!fs.existsSync(manifestPath)) process.exit(0);

  let manifest;
  try {
    manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf8'));
  } catch (err) {
    fail(`could not parse ${MANIFEST}: ${(err && err.message) || err}`);
  }

  const lines = [HEADING];
  const checks = manifest && Array.isArray(manifest.checks) ? manifest.checks : [];
  for (const check of checks) lines.push(`- ${check.name}: ${check.command}`);
  let out = lines.join('\n') + '\n';

  if (manifest && manifest.preamble !== undefined) {
    const preamblePath = path.join(root, manifest.preamble);
    if (!fs.existsSync(preamblePath)) {
      fail(`${MANIFEST} names preamble ${manifest.preamble}, which does not exist`);
    }
    out += '\n' + fs.readFileSync(preamblePath, 'utf8');
  }

  process.stdout.write(out);
  process.exit(0);
} catch (err) {
  fail(`could not print the standards preamble: ${(err && err.message) || err}`);
}
