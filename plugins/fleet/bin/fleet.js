#!/usr/bin/env node
'use strict';

/*
 * fleet — coordinator runtime for agentic-work-packages.
 *
 *   fleet cycle  [--apply] [--json] [--config <file>]   one pass; dry run unless --apply
 *   fleet launch <issue> [--apply] [--config <file>]    launch one package through the cycle's own path
 *   fleet reap   [--apply] [--json]                     classify finished sessions only
 *   fleet status [--json]                               local state and live sessions, read-only
 *   fleet resume --reason <text>                        clear the stop latch
 *   fleet doctor                                        binaries, plugin, labels, contract, hooks, worktreesDir
 *   fleet daemon --config <a.json> [--config <b.json> ...] [--interval <minutes>]
 *                                                       cycle --apply per config on an interval and on worker exit
 *   fleet standards init --target <owner/repo> [--write] draft the target's .claude/standards.json and validate it
 *
 * Config: --config, else FLEET_CONFIG, else ./fleet.config.json.
 * Exit codes: 0 ok · 1 a label write failed · 64 usage · 69 missing binary ·
 * 70 internal · 75 collection truncated · 78 latched · 79 another cycle holds the lock
 */

const fs = require('fs');
const path = require('path');
const { loadConfig } = require('../src/config');
const { Store } = require('../src/store');
const { Tracker } = require('../src/tracker');
const { runCycle, EXIT } = require('../src/cycle');
const reapMod = require('../src/reap');
const report = require('../src/report');
const { run, isAlive } = require('../src/exec');
const trust = require('../src/trust');
const scope = require('../src/scope');

function parse(argv) {
  // flags.config keeps the last --config, as before; configs keeps every one,
  // for the daemon.
  const out = { _: [], flags: {}, configs: [] };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a.startsWith('--')) {
      const k = a.slice(2);
      const next = argv[i + 1];
      if (['config', 'reason', 'issue', 'interval', 'target'].includes(k)) { out.flags[k] = next; i++; if (k === 'config') out.configs.push(next); }
      else out.flags[k] = true;
    } else out._.push(a);
  }
  return out;
}

function usage(code = EXIT.usage) {
  process.stderr.write(fs.readFileSync(__filename, 'utf8').split('\n').slice(4, 20).map(l => l.replace(/^ \*\s?/, '')).join('\n') + '\n');
  process.exit(code);
}

function config(flags) {
  const file = flags.config || process.env.FLEET_CONFIG || 'fleet.config.json';
  try { return loadConfig(file); }
  catch (e) { process.stderr.write(`${e.message}\n`); process.exit(EXIT.usage); }
}

function main() {
  const { _: pos, flags, configs } = parse(process.argv.slice(2));
  const cmd = pos[0];
  if (!cmd || flags.help || cmd === 'help') usage(cmd ? EXIT.ok : EXIT.usage);

  if (cmd === 'daemon') {
    // Runs until SIGTERM/SIGINT; each cycle is `fleet cycle --apply` for one config.
    const files = configs.length ? configs : [process.env.FLEET_CONFIG || 'fleet.config.json'];
    if (files.some(f => f === undefined)) { process.stderr.write('fleet daemon: --config needs a file\n'); process.exit(EXIT.usage); }
    if ('interval' in flags && flags.interval === undefined) { process.stderr.write('fleet daemon: --interval needs a number of minutes\n'); process.exit(EXIT.usage); }
    try { require('../src/daemon').start({ files, intervalMinutes: flags.interval, fleetBin: __filename }); }
    catch (e) {
      if (e.code !== 'EUSAGE' && e.code !== 'ECONFIG') throw e;
      process.stderr.write(`${e.message}\n`); process.exit(EXIT.usage);
    }
    return;
  }

  if (cmd === 'cycle') {
    const cfg = config(flags);
    const { report: r, exit } = runCycle(cfg, { apply: Boolean(flags.apply), log: m => process.stderr.write(`fleet: ${m}\n`) });
    process.stdout.write(flags.json ? JSON.stringify(r, null, 2) + '\n' : report.render(r) + '\n');
    process.stderr.write(report.summarize(r) + '\n');
    process.exit(exit);
  }

  if (cmd === 'launch') {
    // The cycle is the only launch path; this narrows it to one issue so a
    // coordinator can dispatch a single package by hand and still get the
    // same worktree, scope commit, claim and record.
    const n = Number(pos[1] || flags.issue);
    if (!Number.isInteger(n)) usage();
    const cfg = config(flags);
    process.env.FLEET_ONLY_ISSUE = String(n);
    const { report: r, exit } = runCycle(cfg, { apply: Boolean(flags.apply) });
    const mine = r.launched.filter(l => l.issue === n);
    const alarms = r.alarms.filter(a => a.issue === n);
    process.stdout.write(JSON.stringify({ cycleId: r.cycleId, launched: mine, alarms, dryRun: r.dryRun }, null, 2) + '\n');
    process.exit(mine.length ? EXIT.ok : (alarms.length ? EXIT.internal : exit));
  }

  if (cmd === 'standards') {
    // Drafts a manifest for a human to commit. Reads the clone, writes at most
    // one new file with --write, and never stages, commits or pushes.
    if (pos[1] !== 'init') usage();
    if (typeof flags.target !== 'string') { process.stderr.write('fleet standards init: --target <owner/repo> is required\n'); process.exit(EXIT.usage); }
    const cfg = config(flags);
    const target = cfg.targets.find(t => t.repo === flags.target);
    if (!target) {
      process.stderr.write(`fleet standards init: ${flags.target} is not in targets[] (${cfg.targets.map(t => t.repo).join(', ')})\n`);
      process.exit(EXIT.usage);
    }
    const manifestPath = path.join(target.localPath, '.claude', 'standards.json');
    if (flags.write && fs.existsSync(manifestPath)) {
      process.stderr.write(`fleet standards init: ${manifestPath} exists; refusing to overwrite it\n`);
      process.exit(1);
    }
    let draft;
    try { draft = require('../src/standards').draftManifest(target.localPath); }
    catch (e) { process.stderr.write(`fleet standards init: ${e.message}\n`); process.exit(1); }
    const text = JSON.stringify(draft.manifest, null, 2) + '\n';
    process.stdout.write(text);
    for (const n of draft.notes) process.stderr.write(`fleet standards init: ${n}\n`);
    if (flags.write) {
      fs.mkdirSync(path.dirname(manifestPath), { recursive: true });
      fs.writeFileSync(manifestPath, text, { flag: 'wx' });
      process.stderr.write(`fleet standards init: wrote ${manifestPath}; review it and commit it yourself\n`);
    }
    const checker = path.join(cfg.scriptsDir, 'check-standards.js');
    if (!fs.existsSync(checker)) { process.stderr.write(`fleet standards init: no validator at ${checker}; the draft is not validated\n`); process.exit(1); }
    const ls = run(cfg.bins.git, ['-C', target.localPath, 'ls-files', '-z'], { timeoutMs: 60000 });
    if (ls.status !== 0) {
      process.stderr.write(`fleet standards init: git ls-files failed in ${target.localPath}: ${ls.error || ls.stderr.trim()}; the draft is not validated\n`);
      process.exit(1);
    }
    const files = ls.stdout.split('\0').filter(Boolean);
    const v = require(checker).validateStandards({ text, files });
    for (const w of v.warnings) process.stderr.write(`fleet standards init: warning: ${w}\n`);
    if (!v.ok) {
      for (const d of v.defects) process.stderr.write(`fleet standards init: defect: ${d}\n`);
      process.stderr.write('fleet standards init: the draft does not validate\n');
      process.exit(1);
    }
    process.stderr.write('fleet standards init: the draft validates\n');
    process.exit(EXIT.ok);
  }

  if (cmd === 'reap') {
    const cfg = config(flags);
    const store = new Store(cfg.stateDir);
    const tracker = new Tracker(cfg.bins);
    const state = store.load();
    const pulls = [];
    for (const t of cfg.targets) { const p = tracker.listPulls(t.repo); if (p.ok) pulls.push(...p.pulls); }
    const out = reapMod.reap(cfg, state, pulls);
    if (flags.apply) store.save(state);
    process.stdout.write(JSON.stringify({ dryRun: !flags.apply, ...out }, null, 2) + '\n');
    process.exit(EXIT.ok);
  }

  if (cmd === 'status') {
    const cfg = config(flags);
    const store = new Store(cfg.stateDir);
    const state = store.load();
    const sessions = Object.values(state.sessions).map(s => ({ ...s, alive: ['launching', 'running'].includes(s.status) && isAlive(s.pid) }));
    const view = { stateDir: cfg.stateDir, streak: state.streak, latched: state.latched, lastCycleId: state.lastCycleId, unposted: state.unposted, sessions, dispatches: state.dispatches };
    if (flags.json) process.stdout.write(JSON.stringify(view, null, 2) + '\n');
    else {
      process.stdout.write(`state: ${cfg.stateDir}\nstreak: ${state.streak}${state.latched ? `  LATCHED at ${state.latched.at}: ${state.latched.reason}` : ''}\nlast cycle: ${state.lastCycleId || 'none'}\n`);
      for (const s of sessions) process.stdout.write(`  #${s.issue} ${s.id} worker:${s.worker} ${s.status}${s.alive ? ' (alive)' : ''} attempt ${s.attempt} tier ${s.tier} ${s.branch} pid ${s.pid || '-'} ${s.outcome || ''}\n`);
    }
    process.exit(EXIT.ok);
  }

  if (cmd === 'resume') {
    if (!flags.reason) { process.stderr.write('fleet resume: --reason <text> is required; the reason is recorded.\n'); process.exit(EXIT.usage); }
    const cfg = config(flags);
    const store = new Store(cfg.stateDir);
    const state = store.load();
    const was = state.latched;
    state.latched = null; state.streak = 0;
    state.resumes = [...(state.resumes || []), { at: new Date().toISOString(), reason: flags.reason, was }];
    store.save(state);
    process.stdout.write(`latch cleared${was ? ` (was: ${was.reason} at ${was.at})` : ' (was not latched)'}; reason recorded.\n`);
    process.exit(EXIT.ok);
  }

  if (cmd === 'doctor') {
    const cfg = config(flags);
    let bad = 0;
    const check = (ok, label, detail) => { process.stdout.write(`${ok ? 'ok   ' : 'FAIL '} ${label}${detail ? `: ${detail}` : ''}\n`); if (!ok) bad++; };
    for (const [name, bin] of Object.entries(cfg.bins)) { const r = run(bin, ['--version'], { timeoutMs: 15000 }); check(r.status === 0, `${name} (${bin})`, r.status === 0 ? r.stdout.trim().split('\n')[0] : (r.error || r.stderr.trim())); }
    check(fs.existsSync(path.join(cfg.scriptsDir, 'sync-cells.sh')), 'sync-cells.sh', cfg.scriptsDir);
    check(fs.existsSync(path.join(cfg.scriptsDir, 'assign-cells.sh')), 'assign-cells.sh', cfg.scriptsDir);
    check(fs.existsSync(cfg.contractPath), 'worker-contract.md', cfg.contractPath);
    const emit = run('bash', [path.join(cfg.scriptsDir, 'sync-cells.sh'), '--help'], { timeoutMs: 15000 });
    check(/--emit-state/.test(emit.stdout), 'sync-cells.sh supports --emit-state', 'needs agentic-work-packages >= 1.4.1');
    check(/--epic/.test(emit.stdout), 'sync-cells.sh supports --epic', 'needs an agentic-work-packages with sync-cells.sh --epic');
    // The launch precondition instructions-leak, for every worktree under worktreesDir.
    if (cfg.isolateWorkers) {
      const leaks = require('../src/launch').instructionFilesFrom(cfg.worktreesDir);
      check(!leaks.length, `no instruction file in worktreesDir or an ancestor: ${cfg.worktreesDir}`, leaks.length ? `${leaks.join(', ')}; an isolated worker would read ${leaks.length > 1 ? 'them' : 'it'}, so launch refuses instructions-leak. Set worktreesDir to a directory with no CLAUDE.md, CLAUDE.local.md or .claude/CLAUDE.md in it or any ancestor, or set isolateWorkers to false` : '');
    } else check(true, `no instruction file in worktreesDir or an ancestor: ${cfg.worktreesDir}`, 'not checked, isolateWorkers is false');
    for (const t of cfg.targets) {
      check(fs.existsSync(t.localPath), `clone ${t.repo}`, t.localPath);
      const settings = path.join(t.localPath, '.claude', 'settings.json');
      let hooks = false;
      try { const s = JSON.parse(fs.readFileSync(settings, 'utf8')); hooks = JSON.stringify(s).includes('enforce-scope') && JSON.stringify(s).includes('require-handoff'); } catch { /* absent */ }
      check(hooks, `scope + handoff hooks committed in ${t.repo}`, hooks ? settings : `${settings} lacks enforce-scope/require-handoff; a cloud worker sees only committed hooks`);
      const tr = trust.isTrusted(cfg.bins.git, t.localPath);
      check(tr.trusted, `workspace trusted for -p permission rules: ${t.repo}`, tr.trusted ? tr.key : `not trusted; ${trust.howToTrust(tr)}`);
      const contract = path.join(t.localPath, '.claude', 'worker-contract.md');
      check(fs.existsSync(contract), `worker contract installed in ${t.repo}`, contract);
    }
    const tracker = new Tracker(cfg.bins);
    const labels = run(cfg.bins.gh, ['label', 'list', '--repo', cfg.repo, '--limit', '200', '--json', 'name', '--jq', '[.[].name]'], { timeoutMs: 60000 });
    if (labels.status === 0) {
      let have = []; try { have = JSON.parse(labels.stdout); } catch { /* ignore */ }
      for (const l of ['agent-ready', 'cell:queued', 'cell:active', 'cell:awaiting-review', 'cell:blocked', 'cell:merged', 'cell:contract-change', ...cfg.workerIds.map(w => `worker:${w}`)]) check(have.includes(l), `label ${l}`, have.includes(l) ? '' : 'run bootstrap-github-labels.sh');
    } else check(false, `gh label list ${cfg.repo}`, labels.error || labels.stderr.trim());
    const epic = tracker.viewIssue(cfg.repo, cfg.epic);
    check(epic.ok, `epic #${cfg.epic}`, epic.ok ? epic.issue.title : epic.error);
    // A package is an open issue that is agent-ready or already carries a
    // cell:* label; a cycle acts only on those whose **Part of** names the epic.
    const list = tracker.listIssues(cfg.repo);
    if (list.ok) {
      const packages = list.issues.filter(i => String(i.state).toUpperCase() === 'OPEN'
        && i.labels.some(l => l === 'agent-ready' || l.startsWith('cell:')));
      const inEpic = packages.filter(i => scope.partOf(i.body) === cfg.epic).length;
      check(true, `packages of epic #${cfg.epic}`, `${inEpic} open in ${cfg.repo}, ${packages.length - inEpic} open outside the epic`);
    } else check(false, `issue list ${cfg.repo}`, list.error);
    process.exit(bad ? EXIT.internal : EXIT.ok);
  }

  usage();
}

main();
