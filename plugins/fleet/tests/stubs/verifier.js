#!/usr/bin/env node
'use strict';
// Verifier stub for the fleet fixture tests: the lab runner's two routes, on
// loopback, at a fixed port. Stateful through files in VERIFIER_STUB_DIR:
//   script.json  read on every request, so a test can change it between cycles:
//                { "refuse": { "<pr>": "<409 error text>" },
//                  "results": { "<pr>": { "finished": bool, "exitCode": n, "reverted": bool,
//                                         "headSha": "<sha>", "tests": [...], "selection": {...},
//                                         "deployed": [...] } } }
//                A result without headSha takes the PR's headRefOid from the gh
//                stub's prs.json (GH_STUB_DIR) at the time of the POST, as the
//                runner checks out the PR head when it starts.
//   runs.json    every run started, so a stopped and restarted stub keeps them
//   requests.log one line per request: "<iso time> <METHOD> <route> pr=<n|-> <code>"
//   ready        written once the server listens
// Routes:
//   POST /<suite>/verify {"pr": n}  202 {"run":{"id"}}; 409 "a run is already going: ..."
//                                   while any run is unfinished; 409 refuse[pr] when set
//   GET  /runs/<id>                 the run record; finishedAt null until results[pr].finished
// A run is finished the first time a request sees results[pr].finished; the
// result is copied into the run then, so a later edit of results starts the
// next run of that PR, never rewrites a finished one.
const http = require('http');
const fs = require('fs');
const path = require('path');

const DIR = process.env.VERIFIER_STUB_DIR;
const PORT = Number(process.env.VERIFIER_STUB_PORT);
if (!DIR || !PORT) { process.stderr.write('verifier stub: VERIFIER_STUB_DIR and VERIFIER_STUB_PORT are required\n'); process.exit(64); }

const rd = (f, d) => { try { return JSON.parse(fs.readFileSync(path.join(DIR, f), 'utf8')); } catch { return d; } };
const wr = (f, v) => fs.writeFileSync(path.join(DIR, f), JSON.stringify(v, null, 2));
const log = (method, route, pr, code) => fs.appendFileSync(path.join(DIR, 'requests.log'), `${new Date().toISOString()} ${method} ${route} pr=${pr === null || pr === undefined ? '-' : pr} ${code}\n`);

function prHead(pr) {
  const prs = (() => { try { return JSON.parse(fs.readFileSync(path.join(process.env.GH_STUB_DIR || '', 'prs.json'), 'utf8')); } catch { return []; } })();
  const p = prs.find(x => x.number === pr);
  return p ? p.headRefOid : null;
}

// Settle every unfinished run whose result now says finished.
function settle(script) {
  const runs = rd('runs.json', []);
  for (const run of runs) {
    if (run.finishedAt) continue;
    const res = (script.results || {})[String(run.pr)];
    if (!res || !res.finished) continue;
    run.finishedAt = new Date().toISOString();
    run.exitCode = res.exitCode;
    run.tests = res.tests || [];
    run.verify = {
      pr: run.pr, repo: res.repo || 'acme/api',
      headSha: res.headSha !== undefined ? res.headSha : run.headAtStart,
      base: 'main', deployed: res.deployed || [], selection: res.selection || {},
      reverted: res.reverted,
    };
  }
  wr('runs.json', runs);
  return runs;
}

function send(res, code, body) {
  res.writeHead(code, { 'content-type': 'application/json' });
  res.end(JSON.stringify(body));
}

const server = http.createServer((req, res) => {
  let raw = '';
  req.on('data', d => { raw += d; });
  req.on('end', () => {
    const script = rd('script.json', {});
    const runs = settle(script);
    const url = new URL(req.url, 'http://127.0.0.1');
    let m;
    if (req.method === 'POST' && (m = /^\/([A-Za-z0-9_-]+)\/verify$/.exec(url.pathname))) {
      let body;
      try { body = JSON.parse(raw); } catch { log('POST', url.pathname, null, 400); return send(res, 400, { error: 'body is not JSON' }); }
      const pr = body && body.pr;
      if (!Number.isInteger(pr)) { log('POST', url.pathname, null, 400); return send(res, 400, { error: 'pr must be an integer' }); }
      const going = runs.find(r => !r.finishedAt);
      if (going) { log('POST', url.pathname, pr, 409); return send(res, 409, { error: `a run is already going: ${going.id} for PR #${going.pr}` }); }
      const refusal = (script.refuse || {})[String(pr)];
      if (refusal) { log('POST', url.pathname, pr, 409); return send(res, 409, { error: refusal }); }
      const id = `run-${runs.length + 1}`;
      runs.push({ id, suite: m[1], pr, startedAt: new Date().toISOString(), finishedAt: null, exitCode: null, headAtStart: prHead(pr), tests: [], lines: [] });
      wr('runs.json', runs);
      settle(script);   // a result already marked finished finishes this run now
      log('POST', url.pathname, pr, 202);
      return send(res, 202, { run: { id } });
    }
    if (req.method === 'GET' && (m = /^\/runs\/([^/]+)$/.exec(url.pathname))) {
      const run = runs.find(r => r.id === decodeURIComponent(m[1]));
      if (!run) { log('GET', url.pathname, null, 404); return send(res, 404, { error: 'no such run' }); }
      log('GET', url.pathname, run.pr, 200);
      const { headAtStart, ...record } = run;
      return send(res, 200, record);
    }
    log(req.method, url.pathname, null, 404);
    return send(res, 404, { error: 'no such route' });
  });
});

server.listen(PORT, '127.0.0.1', () => { fs.writeFileSync(path.join(DIR, 'ready'), String(process.pid)); });
process.on('SIGTERM', () => server.close(() => process.exit(0)));
