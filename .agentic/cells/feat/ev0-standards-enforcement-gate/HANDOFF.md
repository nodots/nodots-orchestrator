# HANDOFF: EV0

## Done
- Added `plugins/agentic-work-packages/skills/agentic-work-packages/assets/tests/ev0-standards-enforcement-gate.test.sh`: one fixture repo (`development` base, `change` branch), four cases against `run-checks.js --base development`, 14 assertions, all pass.
  - 1 enabled plugin + `true` check -> exit 0
  - 2 plugin not enabled -> exit 2, stderr names `example-standard@example-market` (check-standards.js:127)
  - 3 base `false`, head rewrites to `true` -> exit 1, `FAIL  gate (exit 1)` (run-checks.js:92-108)
  - 4 base without manifest -> exit 2, `run-checks: no .claude/standards.json at development` (run-checks.js:56)

## Not done
- Acceptance "each case fails against the tree before its package" is not shown. Running the test against `f694bad^` (pre-E0.1) and `adaef0b^` (pre-E0.2) needs a git worktree outside this one or a checkout into a forbidden path; both were denied in this session. A reviewer can run it by hand: `git worktree add /tmp/pre f694bad^`, copy the test in, run it.
- The `standards` job on the PR is for CI to run.

## Plan check

Package issue still matches: yes
