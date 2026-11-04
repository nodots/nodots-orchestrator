# BLOCKER: SV0 — the worker session cannot execute the gate or the repo's checks

**Bucket:** on a missing capability
**Kind:** human-decision
**Reference:** issue #123; worker session for branch `test/sv0-standards-gate`, 2026-11-04
**Owner:** the coordinator (Ken Riley)
**Un-blocks when:** a session that is permitted to run `bash` executes
`bash scripts/test.sh` in this worktree and its output is recorded

## What was needed, and why

The package deliverable, the gate test
`plugins/agentic-work-packages/skills/agentic-work-packages/assets/tests/sv0-standards-gate.test.sh`,
is written (uncommitted in the worktree at the time of writing). It asserts the
five scope items of #123:

1. valid fixture: `check-standards.js` exits 0, both `standards-preamble.js`
   copies print heading, every check (built from `fixtures/standards/valid.json`)
   and the preamble, in order;
2. every `fixtures/standards/invalid-*.json`: exit 2, stderr contains
   `standards: .claude/standards.json: <expect>`;
3. `check-standards.js --root <repo root>` exits 0 with only
   `rule has no check` warnings, and each `#fragment` in `.claude/standards.json`
   (`CLAUDE.md#rules`, `CLAUDE.md#where-intent-and-spec-live`) is the slug of a
   heading in its file;
4. the `git grep` and the contract `grep` from #123 print nothing (exit 1 asserted,
   so an erroring grep does not pass);
5. `diff` of the contract asset against `.claude/worker-contract.md` is empty.

Contract §4 and §6 require the test to be run and `bash scripts/test.sh` to end
`ALL PASS` before a `[READY]` PR and a `VERIFIED` stamp. This session denies, as
needing approval it cannot get, every one of: `bash <test>`,
`bash scripts/test.sh`, `node check-standards.js --root <repo>`, `git grep`,
`diff`, and any command that sets a shell variable. None of the assertions has
been executed. Nothing about whether the gate passes is known.

## Alternatives searched

- Run the test file directly (`bash sv0-standards-gate.test.sh`) — denied.
- Run `bash scripts/test.sh` by absolute path — denied.
- Run the individual invariants (`git -C <root> grep`, `grep`, `diff`, `node
  check-standards.js`) one at a time — denied.
- Open the `[READY]` PR without running the checks — forbidden by contract §6
  (a `[READY]` without a current stamp is a false claim).
- Rely on CI to run it — CI is not a stamp by this worker, and the contract says
  someone else's "tests pass" is a pointer to re-query, never a clearance.

## The ask

SV0-run: grant this package's worker permission to run `bash` (or re-dispatch it
to a session that has it), or have a person run `bash scripts/test.sh` in this
worktree, then commit the gate test, stamp, and open the `[READY]: SV0` PR ;
options: (a) re-dispatch with bash allowed, (b) a human runs and stamps :
recommendation (a), because the contract wants the worker that wrote the test to
classify any red it shows : decide-by the next coordinator cycle :
cost-of-waiting Phase 1 (#124, #125, #126) stays undispatched behind this gate.
