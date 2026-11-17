# HANDOFF: E0.2 — `run-checks.js`

## Done

- `plugins/agentic-work-packages/skills/agentic-work-packages/assets/tests/run-checks.test.sh`
  was committed first (cec4c67) and failed against that tree: 39 of 49 checks
  red, the first being `run-checks.js exists`.
- `plugins/agentic-work-packages/skills/agentic-work-packages/assets/scripts/run-checks.js`
  added. Node builtins only. It requires `validateFile` and `validateStandards`
  from `check-standards.js` (`check-standards.js:288`); that file is unchanged.
  - Head: `validateFile(root)`; defects printed as `standards: .claude/standards.json: <d>`,
    the shape `check-standards.js:281` uses; exit 2.
  - Base: `git rev-parse --verify <base>^{commit}` first, so a bad ref is
    reported as `run-checks: cannot resolve base <ref>` and not misread as "no
    manifest". Then `git ls-tree -r -z --name-only <base>`, and
    `git show <base>:.claude/standards.json` through `validateStandards`.
    Missing: `run-checks: no .claude/standards.json at <base>`. Base defects and
    warnings are prefixed `standards: <base>:.claude/standards.json: `, so they are
    told apart from the head's.
  - Checks: `sh -c` with cwd `<root>`, stdio inherited, every check run, then
    `PASS  <name>` / `FAIL  <name> (exit <n>)`. A check killed by a signal prints
    `(signal <SIG>)` and still counts as a failure. The last line is the tally.
- Test cases: all pass (0), one of two fails (1, both run), head invalid or
  missing (2), base missing or invalid (2), base file list from the base tree,
  unresolvable base (2), head rewrites `false` to `true` (1, committed and
  working-tree), head-only check does not run, warnings on stderr with the exit
  code unchanged, usage error (2).

## Next

- E0.3 documents the script in `references/standards.md` (out of this lane).
- The workflow that calls `run-checks.js --base <PR base sha>` is a later package.

## Plan check

Package issue still matches: yes

## Coordinator decision E0.2-B1 (2026-11-17)

Recorded in the epic's decisions log (#219). The CI run stands in for the local
`bash scripts/test.sh` on macOS:

- Open the `[READY]:` PR for head `adaef0b` or later.
- Wait for the `Fixture tests` job in CI to pass at the PR head sha.
- Stamp `VERIFIED: ci-<run id> @ <full head sha>`, with the run URL, and quote the
  local run with only `scripts/tests/check-secrets.test.sh` and
  `scripts/tests/gate-h-hardening.test.sh` red. Any other local red still blocks.

## Attempt 2 (2026-11-17)

- PR #227 opened (`[READY]: E0.2 …`, `Closes #221`) at head `260ee10`.
- CI `Fixture tests` passed: run 44179885654.
- The local `bash scripts/test.sh` finished `FAILED` with a third red file,
  `scripts/tests/v0-gate.test.sh` (2 failed). Its cause is the nested run's same
  two gitleaks reds. The earlier stall was this file running the suite four
  times; it was slow, not hung.
- No stamp posted. Stopped on `BLOCKER.md` (ask E0.2-B2). If the coordinator
  picks (a), stamp with the green CI `Fixture tests` run for the current head.
  This commit moves the head past `260ee10`, so run 44179885654 no longer covers it.

## Coordinator decision E0.2-B2 (2026-11-17)

E0.2-B1 covers any local red whose only cause is the Linux gitleaks pin. The
`v0-gate.test.sh` red (2 of 11, the clean copy not `ALL PASS`) is excepted: its
nested run is red only in `check-secrets.test.sh` and `gate-h-hardening.test.sh`,
both `gitleaks exited 126 ... Exec format error`. Recorded on #219.
