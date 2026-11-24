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
 *   - `gh issue create` (or its alias `gh issue new`), with any labels;
 *   - `gh issue edit` with --add-label or --remove-label (also `--flag=value`,
 *     and comma lists) naming `agent-ready`, `cell:<x>` or `worker:<x>`, in any
 *     letter case (GitHub label names are case-insensitive);
 *   - `gh issue edit` with --body, -b, --body-file, -F, --title or -t, on any
 *     issue: fleet re-reads the lane from the issue body and re-commits it, so a
 *     worker that edits a body could widen its own allowedPaths;
 *   - `gh api` that writes labels, with method POST, PUT, PATCH or DELETE
 *     (-X / --method; a field or --input flag with no method is a POST, as gh
 *     does): `labels` in the endpoint, or a `labels` field (-f, -F, attached
 *     -flabels..., --field, --raw-field). A field on a GET is a query, and is
 *     allowed;
 *   - `gh api` that files an issue (a POST to repos/<o>/<r>/issues) or edits
 *     one (a write to repos/<o>/<r>/issues/<n> with a body or title field, or
 *     with --input, whose contents the hook cannot see).
 *
 * How a command is read: it is split into segments on ; & | ( ) backtick and
 * newline, outside quotes; `$(...)` and backticks inside double quotes open a
 * segment of their own. Backslash-newline joins lines; `#` at the start of a
 * word comments to the end of the line. A heredoc body is data and is skipped,
 * unless the command it feeds is a shell (sh, bash, zsh, dash, ksh), in which
 * case the body is judged as commands; so is a here-string (`bash <<< "..."`)
 * fed to a shell. In each segment the command word is found past shell
 * keywords (if, then, do, while, `{`, `!` ...), `function NAME`, variable
 * assignments and wrappers (env, sudo, timeout, xargs, nohup, nice ...); a
 * `sh -c` string and `eval` arguments are judged as commands, as are the words
 * of each `find -exec`/`-execdir`/`-ok`/`-okdir` (up to `;` or `+`) and of
 * `parallel` (from the first word naming gh, a shell, eval or a wrapper, up
 * to `:::` or `::::`). gh's own
 * subcommand is its first positional word (past -R/--repo), so a flag value
 * such as `--title api` is never read as one. A match in any segment refuses.
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
 *   GitHub tools; `gh api graphql` mutations; gh aliases (`gh alias set`); a
 *   command built at runtime (a variable or command substitution holding the
 *   verb, endpoint or label, a script file, `source`); a shell fed its
 *   commands by a pipe (`cat f | bash`) or a heredoc owned by another segment;
 *   a `<<` shift inside `$(( ))`, which is read as a heredoc and can hide the
 *   lines after it; `gh api` to an issue endpoint given as a full URL other
 *   than api.github.com's path form; `parallel` given its commands as
 *   arguments or from a file (`parallel ::: "gh issue create"`, `parallel
 *   :::: cmds`, `parallel < cmds`); a redirect written before the command
 *   word (`<<< "gh issue create" bash`); a find -exec, a parallel or a
 *   here-string nested deeper than four levels. After a wrapper or
 *   `parallel`, the first later word naming gh, a shell, eval, find or
 *   parallel is taken as the command it runs, so `timeout 5 echo gh issue
 *   create` is refused: a false refusal, not a miss. So are a quoted word
 *   before `:::` that reads as such a command (`parallel echo 'gh issue
 *   create' ::: a`) and a shell argument quoted to start with `<<<`.
 *   Issue comments are not refused: a worker reports on its PR and package. A
 *   design decision a worker records in a comment is a coordination defect the
 *   worker contract already names (write BLOCKER.md); it is not mechanically
 *   checked.
 *
 * Wire it up in .claude/settings.json:
 *   { "hooks": { "PreToolUse": [ { "matcher": "Bash",
 *       "hooks": [ { "type": "command",
 *                    "command": "node .claude/hooks/require-coordinator.js" } ] } ] } }
 */

const HOOK = 'require-coordinator';

const COORDINATOR_LABEL = /^(?:agent-ready|cell:.*|worker:.*)$/i;
const WRITE_METHODS = new Set(['POST', 'PUT', 'PATCH', 'DELETE']);
const SEPARATORS = new Set([';', '&', '|', '(', ')', '`', '\n']);
const ASSIGNMENT = /^[A-Za-z_][A-Za-z0-9_]*=/;
const KEYWORDS = new Set(['if', 'then', 'else', 'elif', 'do', 'while', 'until', '!', '{', '}', 'time']);
const WRAPPERS = new Set([
  'command', 'exec', 'builtin', 'env', 'sudo', 'doas', 'nohup', 'time',
  'timeout', 'xargs', 'nice', 'ionice', 'stdbuf', 'watch', 'caffeinate',
]);
const SHELLS = new Set(['sh', 'bash', 'zsh', 'dash', 'ksh']);
// A heredoc delimiter is a word; `1<<2` is a shift, not a heredoc.
const HEREDOC_DELIM = /^[A-Za-z_][A-Za-z0-9_.-]*$/;
// `gh issue new` is gh's alias for `gh issue create`.
const FILING_VERBS = new Set(['create', 'new']);
const MAX_DEPTH = 4;

const basename = t => t.split('/').pop();

// Splits a command into segments. A segment is { raw, tokens, heredocs }: the
// text it came from, its words with quotes removed, and the bodies of the
// heredocs it reads.
function parse(command) {
  const n = command.length;
  const segments = [];
  let tokens = [];
  let heredocs = [];
  let word = null;
  let start = 0;
  let quote = null;
  const stack = [];    // open substitutions: { close, outer quote to restore }
  let pending = [];    // heredocs whose body starts at the next newline
  const endWord = () => { if (word !== null) { tokens.push(word); word = null; } };
  const endSegment = (i) => {
    endWord();
    if (tokens.length) {
      const seg = { raw: command.slice(start, i).trim(), tokens, heredocs };
      segments.push(seg);
      for (const p of pending) if (p.owner === null) p.owner = seg;
    }
    tokens = [];
    heredocs = [];
    start = i + 1;
  };
  // Reads the pending heredoc bodies from pos; returns where commands resume.
  const readBodies = (pos) => {
    for (const p of pending) {
      let body = '';
      while (pos < n) {
        let eol = command.indexOf('\n', pos);
        if (eol < 0) eol = n;
        const line = command.slice(pos, eol);
        pos = eol + 1;
        if ((p.strip ? line.replace(/^\t+/, '') : line) === p.delim) break;
        body += line + '\n';
      }
      if (p.owner) p.owner.heredocs.push(body);
    }
    pending = [];
    return pos;
  };
  const close = (i) => {
    endSegment(i);
    quote = stack.pop().outer;
    if (quote) word = '';
  };

  for (let i = 0; i < n; i++) {
    const c = command[i];
    const top = stack[stack.length - 1];
    if (quote === "'") {
      if (c === "'") quote = null; else word += c;
      continue;
    }
    if (quote === '"') {
      if (c === '"') quote = null;
      else if (c === '\\' && command[i + 1] === '\n') i++;
      else if (c === '\\' && i + 1 < n) word += command[++i];
      else if (c === '$' && command[i + 1] === '(') {
        stack.push({ close: ')', outer: '"' });
        quote = null;
        endSegment(++i);
      } else if (c === '`') {
        stack.push({ close: '`', outer: '"' });
        quote = null;
        endSegment(i);
      } else word += c;
      continue;
    }
    if (c === '\\' && command[i + 1] === '\n') { i++; continue; }
    if (c === '\\' && i + 1 < n) {
      if (word === null) word = '';
      word += command[++i];
    } else if (c === "'" || c === '"') {
      quote = c;
      if (word === null) word = '';
    } else if (c === '#' && word === null) {
      while (i + 1 < n && command[i + 1] !== '\n') i++;
    } else if (c === '<' && command.startsWith('<<<', i)) {
      // An operator: it ends the word before it (`bash<<<x`, `0<<<x`), and
      // its own word is `<<<` plus what follows it unspaced.
      endWord();
      word = '<<<';
      i += 2;
    } else if (c === '<' && command[i + 1] === '<') {
      // A heredoc: `<<WORD`, `<<-WORD`, `<<'WORD'`, `<<"WORD"`.
      let j = i + 2;
      const strip = command[j] === '-';
      if (strip) j++;
      while (command[j] === ' ' || command[j] === '\t') j++;
      let delim = '';
      let q = null;
      for (; j < n; j++) {
        const d = command[j];
        if (q) { if (d === q) q = null; else delim += d; }
        else if (d === "'" || d === '"') q = d;
        else if (d === '\\' && j + 1 < n) delim += command[++j];
        else if (/[\s;&|()<>`]/.test(d)) break;
        else delim += d;
      }
      if (HEREDOC_DELIM.test(delim)) {
        endWord();
        // Its owner is the segment it appears in, set when that segment ends.
        pending.push({ delim, strip, owner: null });
        i = j - 1;
      } else {
        if (word === null) word = '';
        word += '<<';
        i++;
      }
    } else if (c === '\n') {
      endSegment(i);
      if (pending.length) {
        const pos = readBodies(i + 1);
        start = pos;
        i = pos - 1;
      }
    } else if (c === ')' && top && top.close === ')') {
      close(i);
    } else if (c === '`' && top && top.close === '`') {
      close(i);
    } else if (SEPARATORS.has(c)) {
      if (c === '(') stack.push({ close: ')', outer: null });
      else if (c === '`') stack.push({ close: '`', outer: null });
      endSegment(i);
    } else if (c === ' ' || c === '\t' || c === '\r') {
      endWord();
    } else {
      if (word === null) word = '';
      word += c;
    }
  }
  endSegment(n);
  return segments;
}

// The index of the word a segment runs, past keywords, assignments and
// wrappers; -1 when there is none.
function commandIndex(tokens) {
  let i = 0;
  for (;;) {
    if (KEYWORDS.has(tokens[i]) || ASSIGNMENT.test(tokens[i] || '')) i++;
    // `function f { ...`: the body's first command follows the name.
    else if (tokens[i] === 'function') i += 2;
    else break;
  }
  while (i < tokens.length && WRAPPERS.has(basename(tokens[i]))) {
    // A wrapper's own options and operands come before the command it runs.
    const j = tokens.findIndex((t, k) => k > i && isRunner(basename(t)));
    if (j < 0) return -1;
    i = j;
  }
  return i < tokens.length ? i : -1;
}

function isRunner(b) {
  return b === 'gh' || b === 'eval' || b === 'find' || b === 'parallel' ||
    SHELLS.has(b) || WRAPPERS.has(b);
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

// gh's positional words with their indexes, skipping -R/--repo and its value.
function positionals(args) {
  const out = [];
  for (let i = 0; i < args.length; i++) {
    const t = args[i];
    if (t === '-R' || t === '--repo') { i++; continue; }
    if (t.startsWith('-')) continue;
    out.push(i);
  }
  return out;
}

function judgeIssueEdit(rest) {
  for (let i = 0; i < rest.length; i++) {
    const t = rest[i];
    if (t === '-R' || t === '--repo') { i++; continue; }
    let skipped = false;
    for (const long of ['--add-label', '--remove-label']) {
      const f = flagValue(rest, i, long);
      if (f) {
        if (labelsCoordinator(f.value)) return `writes a coordinator label (${long} ${f.value})`;
        i += f.skip;
        skipped = true;
      }
    }
    if (skipped) continue;
    if (/^--(?:body|body-file|title)(?:=|$)/.test(t) || /^-[bFt]/.test(t) && !t.startsWith('--')) {
      return 'edits an issue body or title';
    }
  }
  return null;
}

const API_VALUE_FLAGS = new Set([
  '-H', '--header', '-q', '--jq', '-t', '--template', '--hostname', '--cache',
  '-p', '--preview',
]);

function judgeApi(rest) {
  let method = null;
  let endpoint = null;
  let hasInput = false;
  const fields = [];
  for (let i = 0; i < rest.length; i++) {
    const t = rest[i];
    let m;
    if (t === '-X' || t === '--method') { method = (rest[++i] || '').toUpperCase(); continue; }
    if ((m = /^(?:-X|--method=)(.+)$/.exec(t))) { method = m[1].toUpperCase(); continue; }
    if (/^(?:-f|-F|--field|--raw-field)$/.test(t)) { fields.push(rest[++i] || ''); continue; }
    if ((m = /^(?:--field=|--raw-field=|-f|-F)(.+)$/.exec(t))) { fields.push(m[1]); continue; }
    if (t === '--input') { hasInput = true; i++; continue; }
    if (t.startsWith('--input=')) { hasInput = true; continue; }
    if (API_VALUE_FLAGS.has(t)) { i++; continue; }
    if (t.startsWith('-')) continue;
    if (endpoint === null) endpoint = t;
  }
  const keys = fields.map(f => f.split('=')[0]);
  const effective = method || (fields.length || hasInput ? 'POST' : 'GET');
  // A field on a GET is a query parameter, so only a write sends labels.
  if (!WRITE_METHODS.has(effective)) return null;
  if (keys.some(k => /^labels/i.test(k))) return 'writes a labels field through gh api';
  if (endpoint === null) return null;
  const path = endpoint.replace(/^https?:\/\/[^/]+\//, '').replace(/^\/+/, '').split('?')[0];
  if (/(?:^|\/)labels(?:\/|$)/.test(path)) return `writes labels through gh api (${effective})`;
  if (/^repos\/[^/]+\/[^/]+\/issues\/?$/.test(path) && effective === 'POST') {
    return 'files an issue through gh api';
  }
  if (/^repos\/[^/]+\/[^/]+\/issues\/[^/]+\/?$/.test(path) &&
      (hasInput || keys.some(k => /^(?:body|title)$/i.test(k)))) {
    return 'edits an issue body or title through gh api';
  }
  return null;
}

// Why this gh invocation (the words after `gh`) is refused, or null.
function judgeGh(args) {
  const pos = positionals(args);
  if (!pos.length) return null;
  const cmd = args[pos[0]];
  if (cmd === 'api') return judgeApi(args.slice(pos[0] + 1));
  if (cmd !== 'issue' || pos.length < 2) return null;
  const verb = args[pos[1]];
  if (FILING_VERBS.has(verb)) return 'files an issue';
  if (verb === 'edit') return judgeIssueEdit(args.slice(pos[1] + 1));
  return null;
}

// `find ... -exec CMD ... ;` (or `+`): each -exec/-execdir/-ok/-okdir command,
// run directly with no shell, judged as words.
function judgeFind(rest, depth) {
  for (let i = 0; i < rest.length; i++) {
    if (!/^-(?:exec|execdir|ok|okdir)$/.test(rest[i])) continue;
    let end = i + 1;
    while (end < rest.length && rest[end] !== ';' && rest[end] !== '+') end++;
    const why = judgeSegment({ tokens: rest.slice(i + 1, end), heredocs: [] }, depth + 1);
    if (why) return why;
    i = end;
  }
  return null;
}

// `parallel [options] CMD ... ::: args`: parallel hands a shell the words
// before the first argument separator. Each word is judged as a command line
// (a quoted `'cd x && gh ...'`), and so are the words from the first one
// naming a command, joined.
function judgeParallel(rest, depth) {
  let end = rest.findIndex(t => /^:{3,4}\+?$/.test(t));
  if (end < 0) end = rest.length;
  const words = rest.slice(0, end);
  for (const w of words) {
    const why = /\s/.test(w) ? nested(w, depth) : null;
    if (why) return why;
  }
  const k = words.findIndex(t => isRunner(basename(t)));
  return k < 0 ? null : nested(words.slice(k).join(' '), depth);
}

function judgeSegment(seg, depth) {
  const i = commandIndex(seg.tokens);
  if (i < 0) return null;
  const b = basename(seg.tokens[i]);
  const rest = seg.tokens.slice(i + 1);
  if (b === 'gh') return judgeGh(rest);
  if (depth >= MAX_DEPTH) return null;
  if (b === 'eval') return nested(rest.join(' '), depth);
  if (b === 'find') return judgeFind(rest, depth);
  if (b === 'parallel') return judgeParallel(rest, depth);
  if (SHELLS.has(b)) {
    const c = rest.findIndex(t => /^-[A-Za-z]*c[A-Za-z]*$/.test(t));
    if (c >= 0 && rest[c + 1] !== undefined) {
      const why = nested(rest[c + 1], depth);
      if (why) return why;
    }
    // A here-string: `<<< word` or `<<<word`.
    for (let h = 0; h < rest.length; h++) {
      if (!rest[h].startsWith('<<<')) continue;
      const body = rest[h] === '<<<' ? rest[h + 1] : rest[h].slice(3);
      const why = body === undefined ? null : nested(body, depth);
      if (why) return why;
    }
    for (const body of seg.heredocs) {
      const why = nested(body, depth);
      if (why) return why;
    }
  }
  return null;
}

function nested(command, depth) {
  const hit = judge(command, depth + 1);
  return hit ? hit.why : null;
}

function judge(command, depth = 0) {
  for (const seg of parse(command)) {
    const why = judgeSegment(seg, depth);
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
