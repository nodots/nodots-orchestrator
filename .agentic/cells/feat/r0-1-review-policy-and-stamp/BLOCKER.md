# BLOCKER: R0.1 — the fleet gh stub answers the new manifest read with `[]`, and the fleet tests go red

**Bucket:** blocked on a decision
**Kind:** human-decision
**Reference:** #174; `plugins/fleet/tests/stubs/gh.js:115`; branch `feat/r0-1-review-policy-and-stamp` @ b68ca39
**Owner:** the coordinator
**Un-blocks when:** the package issue and SCOPE.json allow `plugins/fleet/tests/stubs/gh.js`, or a package that changes the stub merges into `development`

## What was needed, and why
The issue requires `sync-cells.sh` to read the target's `review` policy from
its default branch. The collector now calls
`gh api repos/<repo>/contents/.claude/standards.json` (raw), but only for a
repo with an open PR that carries a current VERIFIED stamp. A 404 means no
policy. A manifest that is not a JSON object, or a `review` with a defect,
fails the run (exit 78).

The fleet test stub answers every endpoint it does not recognize with `[]` and
exit 0 (`plugins/fleet/tests/stubs/gh.js:115`). So every fleet cycle test with
a stamped PR now gets a "manifest" of `[]`. Sync then exits 78 with
`manifest: must be a JSON object`, and fleet reports `sync-failed`.

`bash scripts/test.sh` at b68ca39 ends `FAILED`:
- `plugins/fleet/tests/verify-manual.test.sh`: 4 of 26 failed
- `plugins/fleet/tests/verify-stage.test.sh`: 26 of 90 failed
- `scripts/tests/v0-gate.test.sh`: 2 of 11 failed (it re-runs test.sh on a clean copy)

Everything else passes, including `check-standards.test.sh` (94/94) and
`sync-cells.test.sh` (116/116). This is a deterministic red, the same
`sync-failed` shape in every failing case, so it gets no re-run.

`plugins/fleet/**` is in `forbiddenPaths`.

## Alternatives searched
- Treat a non-object response as "no policy". This is a fallback that turns a
  broken manifest on the default branch into a silently unenforced policy, and
  the worker contract §4 forbids it.
- Read through the contents API JSON (`{type, content}`) instead of raw. The
  stub still answers `[]` with exit 0, which on GitHub means a directory. That is
  still not "absent", so the run still fails. It would also only move the
  special case.
- Skip the read when no PR has a REVIEWED stamp. Wrong: with a policy of
  `passes ≥ 1` and no stamps, the PR must read `cell:awaiting-reviewer`. Without
  the read it would read `cell:awaiting-review`, which breaks acceptance
  criterion 3.
- Change the fleet tests to give each repo a manifest. Same forbidden path.

## The ask
R0.1-stub: may R0.1's lane add `plugins/fleet/tests/stubs/gh.js`, to answer
`contents/.claude/standards.json` from the stub's remote the way it answers
`BLOCKER.md`: the default branch's file when present, otherwise
`gh: Not Found (HTTP 404)` and exit 1? Options: (a) widen R0.1's issue and
SCOPE.json to that one file; (b) cut the stub change as its own package that
R0.1 depends on; (c) change the design to read the policy some other way. :
recommend (a). It is a one-case stub change that the read makes necessary,
roughly:

```js
if ((m = /repos\/.+?\/contents\/\.claude\/standards\.json$/.exec(ep))) {
  try { out(execFileSync('git', ['--git-dir', REMOTE, 'show', 'HEAD:.claude/standards.json'], { encoding: 'utf8' })); process.exit(0); }
  catch { process.stderr.write('gh: Not Found (HTTP 404)\n'); process.exit(1); }
}
```

: decide-by the next coordinator cycle : cost-of-waiting R0.1 cannot be stamped,
so R0.2, R0.3 and RV, which depend on it, stay queued.
