#!/usr/bin/env node
'use strict';

/*
 * aei-epic.js — enumerate an epic's package checklist as AEI v1 JSON.
 *
 * Optional. It exists so an adopter who also runs a runtime stop guard gets
 * that guard's manufactured-stop denial over this model's own backlog. nodots
 * works without one: the coordinator's stopping condition
 * (references/coordination.md §The stopping condition) stands on its own.
 *
 * What this is for: a stop guard asks "is the backlog really drained?" and must
 * not take the answer from the agent that wants to stop. So this provider reads
 * the epic from the tracker itself and emits what it finds.
 *
 * Consequently there is NO flag that accepts an item list, a count, or a
 * completeness assertion. The only inputs are a tracker locator (--repo/--epic)
 * or a path to the epic body (--epic-file). Adding such a flag would defeat the
 * only property the provider has.
 *
 * Fail closed. A malformed item, a duplicate id, a blocker kind outside the
 * closed vocabulary, or a missing workstreams section is an enumerator error:
 * a non-zero exit and nothing on stdout. An empty backlog is a valid
 * enumeration; an unreadable one never is. A guard reading this treats the
 * error as cannot-evaluate, which for a stop means deny.
 *
 * The line grammar is GitHub's own task-list syntax, so the epic keeps
 * rendering its checkbox progress, with one optional machine-readable suffix:
 *
 *   - [ ] #105 · M1.3 Server-side move validation
 *   - [x] #103 · M1.1 Game session store
 *   - [ ] #110 · M1.1k Session expiry sweep :: blocker:human-decision=product-owner
 *   - [ ] #106 · **V1 gate** — two headless clients complete a game
 *   - [ ] M2.4 Spectator mode                       (proposed: no issue filed yet)
 *
 * Mapping to AEI v1:
 *
 *   [x]                       -> state closed
 *   [ ] with an issue ref     -> state open, granted true
 *   [ ] with no issue ref     -> state proposed, granted false (a draft entry)
 *   :: blocker:<kind>=<ref>   -> a terminal blocker, kinds as in
 *                                coordination.md §BLOCKER.md
 *   no blocker suffix         -> no blocker: the item enumerates as ACTIONABLE
 *
 * That last line is the point of the N-8 kind vocabulary. A package whose
 * BLOCKER.md says only "blocked" carries no kind, so it appears here with no
 * blocker and is actionable — never excused. "We stopped looking" cannot be
 * spelled in this grammar.
 *
 * Usage:
 *   aei-epic.js --repo <owner>/<repo> --epic <issue-number>
 *   aei-epic.js --epic-file <path>
 *
 * Registry (the guard's side) pins a fixed argv; see
 * references/coordination.md §Running with AIQT Guardrails.
 */

const fs = require('fs');
const { execFileSync } = require('child_process');

const TOOL = 'aei-epic';
const ERR = 70; // any non-zero exit is an enumerator error to the caller
const KINDS = new Set([
  'tracked-task', 'human-decision', 'external', 'foreign-lease', 'not-before',
]);

function fail(message) {
  process.stderr.write(`${TOOL}: ${message}\n`);
  process.exit(ERR);
}

function parseArgs(argv) {
  const out = { repo: null, epic: null, file: null };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--repo') out.repo = argv[++i];
    else if (a === '--epic') out.epic = argv[++i];
    else if (a === '--epic-file') out.file = argv[++i];
    else if (a === '-h' || a === '--help') {
      process.stdout.write(
        'usage: aei-epic.js --repo <owner>/<repo> --epic <n>\n' +
        '       aei-epic.js --epic-file <path>\n');
      process.exit(0);
    } else fail(`unknown argument: ${a}`);
  }
  return out;
}

function readFromGitHub(repo, epic) {
  let raw;
  try {
    raw = execFileSync('gh', ['issue', 'view', String(epic), '--repo', repo,
                              '--json', 'body,updatedAt,url'],
                       { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
  } catch (e) {
    fail(`could not read epic ${epic} from ${repo}: ${(e && e.message) || e}`);
  }
  let issue;
  try { issue = JSON.parse(raw); } catch { fail('gh returned output that is not JSON'); }
  if (typeof issue.body !== 'string') fail('the epic has no body to enumerate');
  return { body: issue.body, locator: issue.url || `${repo}#${epic}`, revision: issue.updatedAt || '' };
}

function readFromFile(path) {
  let body, stat;
  try {
    body = fs.readFileSync(path, 'utf8');
    stat = fs.statSync(path);
  } catch (e) {
    fail(`could not read ${path}: ${(e && e.message) || e}`);
  }
  return { body, locator: path, revision: stat.mtime.toISOString() };
}

// The workstreams section is the package list. The epic's other checkbox lists
// — definition of done, success criteria — are not packages and must not be
// enumerated as backlog.
function workstreamsLines(body) {
  const lines = body.split(/\r?\n/);
  let start = -1;
  for (let i = 0; i < lines.length; i++) {
    if (/^#{1,6}\s+workstreams\b/i.test(lines[i])) { start = i + 1; break; }
  }
  if (start === -1) return null;
  const out = [];
  for (let i = start; i < lines.length; i++) {
    if (/^#{1,6}\s/.test(lines[i])) break;
    out.push(lines[i]);
  }
  return out;
}

const CANDIDATE = /^\s*[-*]\s*\[/;
const ITEM = /^\s*[-*]\s*\[([ xX])\]\s*(\S.*?)\s*$/;
const REF = /^#(\d+)\s*[·\-—:]?\s*(.*)$/;
const IDENT = /^([A-Za-z][A-Za-z0-9_.-]*)\b/;
const BLOCKER = /::\s*blocker:([A-Za-z-]+)=(\S+)/;
const OBSERVED = /::\s*observed=(\S+)/;
const EVIDENCE = /::\s*evidence=([^:]+?)(?:\s*::|$)/;

function parseItems(lines) {
  const items = [];
  const seen = new Set();
  lines.forEach((line, n) => {
    if (!CANDIDATE.test(line)) return;          // prose and blank lines are not items
    const m = ITEM.exec(line);
    if (!m) fail(`malformed checklist line ${n + 1}: ${line.trim()}`);

    const closed = m[1] !== ' ';
    let rest = m[2];

    const blockerMatch = BLOCKER.exec(rest);
    const observedMatch = OBSERVED.exec(rest);
    const evidenceMatch = EVIDENCE.exec(rest);
    // A suffix that claims structure it does not have is malformed, not excused.
    if (/::\s*blocker:/.test(rest) && !blockerMatch) {
      fail(`malformed blocker suffix on line ${n + 1}: ${line.trim()}`);
    }
    if (blockerMatch && !KINDS.has(blockerMatch[1])) {
      fail(`unknown blocker kind "${blockerMatch[1]}" on line ${n + 1}; ` +
           `the vocabulary is ${[...KINDS].join(', ')}`);
    }
    rest = rest.split('::')[0].trim();

    const refMatch = REF.exec(rest);
    let issue = null;
    if (refMatch) { issue = Number(refMatch[1]); rest = refMatch[2].trim(); }

    const title = rest.replace(/\*/g, '').trim();
    if (!title) fail(`checklist line ${n + 1} has no title: ${line.trim()}`);
    const idMatch = IDENT.exec(title);
    if (!idMatch) fail(`checklist line ${n + 1} has no package id: ${line.trim()}`);
    const id = idMatch[1];

    if (seen.has(id)) fail(`duplicate package id "${id}" on line ${n + 1}`);
    seen.add(id);

    const item = {
      id,
      title,
      state: closed ? 'closed' : (issue === null ? 'proposed' : 'open'),
      granted: issue !== null,
    };
    if (issue !== null) item.issue = issue;
    if (blockerMatch) {
      item.blocker = {
        kind: blockerMatch[1],
        ref: blockerMatch[2],
        evidence: evidenceMatch ? evidenceMatch[1].trim() : '',
        observed_at_utc: observedMatch ? observedMatch[1] : '',
      };
    }
    items.push(item);
  });
  return items;
}

function main() {
  const args = parseArgs(process.argv.slice(2));
  let src;
  if (args.file) {
    if (args.repo || args.epic) fail('--epic-file takes no --repo or --epic');
    src = readFromFile(args.file);
  } else if (args.repo && args.epic) {
    src = readFromGitHub(args.repo, args.epic);
  } else {
    fail('need --epic-file <path>, or --repo <owner>/<repo> with --epic <n>');
  }

  const lines = workstreamsLines(src.body);
  if (lines === null) fail('no "Workstreams" section in the epic: nothing to enumerate');

  const now = new Date().toISOString();
  process.stdout.write(JSON.stringify({
    version: 1,
    generated_at_utc: now,
    source: { locator: src.locator, revision: src.revision, observed_at_utc: now },
    items: parseItems(lines),
  }, null, 2) + '\n');
}

main();
