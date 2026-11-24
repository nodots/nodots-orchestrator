#!/usr/bin/env node
'use strict';

/*
 * Coordinator-only filing hook (self-contained; Node builtins only).
 *
 * PreToolUse, Bash: in a session with FLEET_WORKER_ID set, refuses a command
 * that files an issue or writes a coordinator label. Only the coordinator files
 * packages and applies `agent-ready`, `cell:*` and `worker:*`; a worker that
 * finds more work writes BLOCKER.md naming it, and the coordinator files it.
 *
 * Refused, when FLEET_WORKER_ID is set:
 *   - `gh issue create`, with any labels;
 *   - `gh issue edit` with --add-label or --remove-label (also `--flag=value`,
 *     and comma lists) naming `agent-ready`, `cell:<x>` or `worker:<x>`;
 *   - `gh issue edit` with --body, -b, --body-file, -F, --title or -t, on any
 *     issue: fleet re-reads the lane from the issue body and re-commits it, so a
 *     worker that edits a body could widen its own allowedPaths;
 *   - `gh api` with `labels` in the path and method POST, PUT, PATCH or DELETE
 *     (-X / --method; a field or --input flag with no method is a POST), or a
 *     `labels` field (-f labels..., -F labels...).
 *
 * The command is split on ; & | ( ) backtick and newline, outside quotes, and
 * each segment is judged on its own: a match in any segment refuses the call.
 *
 * Control header
 * --------------
 * Default: deny, for the forms above, in a session with FLEET_WORKER_ID set.
 *   Without the variable the hook does nothing. A refusal is exit 2 with the
 *   reason on stderr, never a permission ask: an ask hands the worker the
 *   click-through on its own confinement, and wedges an unattended run.
 * Fail posture: open, and loud. Any error evaluating the command exits 0 after
 *   one stderr line naming this hook and the error. Open, because this is a
 *   coordination guardrail and not a security control; loud, because a silent
 *   exit 0 is indistinguishable from "allowed".
 * Residue — what is still not caught: a session without FLEET_WORKER_ID; MCP
 *   GitHub tools; `gh api graphql` mutations; a command built at runtime (eval,
 *   a script file, a variable holding the verb); a subshell inside double
 *   quotes. Issue comments are not refused: a worker reports on its PR and
 *   package. A design decision a worker records in a comment is a coordination
 *   defect the worker contract already names (write BLOCKER.md); it is not
 *   mechanically checked.
 *
 * Wire it up in .claude/settings.json:
 *   { "hooks": { "PreToolUse": [ { "matcher": "Bash",
 *       "hooks": [ { "type": "command",
 *                    "command": "node .claude/hooks/require-coordinator.js" } ] } ] } }
 */

const HOOK = 'require-coordinator';

const COORDINATOR_LABEL = /^(?:agent-ready|cell:.*|worker:.*)$/;
const WRITE_METHODS = new Set(['POST', 'PUT', 'PATCH', 'DELETE']);
const WRAPPERS = new Set(['command', 'exec', 'env', 'sudo', 'nohup', 'time']);
const SEPARATORS = new Set([';', '&', '|', '(', ')', '`', '\n']);

// Splits a command into segments of tokens, quote-aware. A segment is
// { raw, tokens }: the text it came from, and its words with quotes removed.
function parse(command) {
  const segments = [];
  let tokens = [];
  let word = null;
  let start = 0;
  let quote = null;
  const endWord = () => { if (word !== null) { tokens.push(word); word = null; } };
  const endSegment = (i) => {
    endWord();
    if (tokens.length) segments.push({ raw: command.slice(start, i).trim(), tokens });
    tokens = [];
    start = i + 1;
  };
  for (let i = 0; i < command.length; i++) {
    const c = command[i];
    if (quote === "'") {
      if (c === "'") quote = null; else word += c;
    } else if (quote === '"') {
      if (c === '"') quote = null;
      else if (c === '\\' && i + 1 < command.length) { word += command[++i]; }
      else word += c;
    } else if (c === "'" || c === '"') {
      quote = c;
      if (word === null) word = '';
    } else if (c === '\\' && i + 1 < command.length) {
      if (word === null) word = '';
      word += command[++i];
    } else if (SEPARATORS.has(c)) {
      endSegment(i);
    } else if (c === ' ' || c === '\t' || c === '\r') {
      endWord();
    } else {
      if (word === null) word = '';
      word += c;
    }
  }
  endSegment(command.length);
  return segments;
}

// The words that follow `gh`, or null when the segment does not run gh.
function ghArgs(tokens) {
  let i = 0;
  while (i < tokens.length && (/^[A-Za-z_][A-Za-z0-9_]*=/.test(tokens[i]) || WRAPPERS.has(tokens[i]))) i++;
  if (i >= tokens.length) return null;
  const bin = tokens[i].split('/').pop();
  return bin === 'gh' ? tokens.slice(i + 1) : null;
}

// The value of a flag at args[i]: ["--add-label", "x"] or ["--add-label=x"].
function flagValue(args, i, long) {
  const t = args[i];
  if (t === long) return { value: args[i + 1] === undefined ? '' : args[i + 1], skip: 1 };
  if (t.startsWith(long + '=')) return { value: t.slice(long.length + 1), skip: 0 };
  return null;
}

function labelsCoordinator(value) {
  return value.split(',').some(l => COORDINATOR_LABEL.test(l.trim()));
}

// Why this gh invocation is refused, or null.
function judgeIssue(args) {
  const at = args.findIndex((a, i) => a === 'issue' && (args[i + 1] === 'create' || args[i + 1] === 'edit'));
  if (at < 0) return null;
  const verb = args[at + 1];
  if (verb === 'create') return 'files an issue';
  const rest = args.slice(at + 2);
  for (let i = 0; i < rest.length; i++) {
    const t = rest[i];
    for (const long of ['--add-label', '--remove-label']) {
      const f = flagValue(rest, i, long);
      if (f) {
        if (labelsCoordinator(f.value)) return `writes a coordinator label (${long} ${f.value})`;
        i += f.skip;
      }
    }
    if (/^--(?:body|body-file|title)(?:=|$)/.test(t) || /^-[bFt]/.test(t) && !t.startsWith('--')) {
      return 'edits an issue body or title';
    }
  }
  return null;
}

const API_VALUE_FLAGS = new Set([
  '-X', '--method', '-f', '--raw-field', '-F', '--field', '-H', '--header',
  '--input', '-q', '--jq', '-t', '--template', '--hostname', '--cache',
]);

function judgeApi(args) {
  const at = args.indexOf('api');
  if (at < 0) return null;
  const rest = args.slice(at + 1);
  let method = null;
  let labelsPath = false;
  let hasBody = false;
  let labelsField = false;
  for (let i = 0; i < rest.length; i++) {
    const t = rest[i];
    let m;
    if ((m = /^(?:-X|--method=)(.+)$/.exec(t)) && t !== '--method') { method = m[1].toUpperCase(); continue; }
    if (t === '-X' || t === '--method') { method = (rest[++i] || '').toUpperCase(); continue; }
    if (/^(?:-f|-F|--field|--raw-field)$/.test(t)) {
      hasBody = true;
      if (/^labels/.test(rest[++i] || '')) labelsField = true;
      continue;
    }
    if ((m = /^(?:--field|--raw-field)=(.*)$/.exec(t))) {
      hasBody = true;
      if (/^labels/.test(m[1])) labelsField = true;
      continue;
    }
    if (t === '--input' || t.startsWith('--input=')) { hasBody = true; if (t === '--input') i++; continue; }
    if (API_VALUE_FLAGS.has(t)) { i++; continue; }
    if (t.startsWith('-')) continue;
    if (/labels/.test(t)) labelsPath = true;
  }
  if (labelsField) return 'writes a labels field through gh api';
  const effective = method || (hasBody ? 'POST' : 'GET');
  if (labelsPath && WRITE_METHODS.has(effective)) return `writes labels through gh api (${effective})`;
  return null;
}

function judge(command) {
  for (const seg of parse(command)) {
    const args = ghArgs(seg.tokens);
    if (!args) continue;
    const why = judgeIssue(args) || judgeApi(args);
    if (why) return { segment: seg.raw, why };
  }
  return null;
}

let input = '';
process.stdin.setEncoding('utf8');
process.stdin.on('data', c => { input += c; });
process.stdin.on('end', () => {
  try {
    const event = JSON.parse(input);
    if (!process.env.FLEET_WORKER_ID) process.exit(0);
    const command = event && event.tool_input && event.tool_input.command;
    if (typeof command !== 'string' || !command) process.exit(0);

    const hit = judge(command);
    if (!hit) process.exit(0);
    // Deny, never ask: stderr carries the reason, exit 2 blocks the call.
    process.stderr.write(
      `${HOOK}: refused. This command ${hit.why}: ${hit.segment}\n` +
      `Only the coordinator files packages and applies agent-ready, cell:* and worker:* labels, ` +
      `or edits an issue body or title. Write BLOCKER.md naming the work you found; ` +
      `the coordinator files it.\n`
    );
    process.exit(2);
  } catch (err) {
    // Fail open, but never silently.
    try {
      process.stderr.write(
        `${HOOK}: could not evaluate this command, allowing it. ` +
        `${(err && err.message) || err}\n`
      );
    } catch { /* stderr gone; there is nothing further this hook can do */ }
    process.exit(0);
  }
});
