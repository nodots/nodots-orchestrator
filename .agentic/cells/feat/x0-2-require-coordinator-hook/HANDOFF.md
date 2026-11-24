# HANDOFF: X0.2 require-coordinator hook

## Done
- `plugins/agentic-work-packages/hooks/require-coordinator.js` and its byte-identical asset copy: with `FLEET_WORKER_ID` set, refuses `gh issue create`, coordinator-label writes (`gh issue edit`, `gh api`), and `gh issue edit` body/title flags. Quote-aware segment split; fail open and loud.
- Wired in `hooks/hooks.json` and `assets/settings-snippet.json` (PreToolUse, Bash).
- `assets/tests/require-coordinator.test.sh` (100 checks).
- Attempt 2 review: `gh issue new` (gh's alias for `issue create`) bypassed the hook; test added first (failed 2), fixed via `ISSUE_VERBS`. Also covers `gh -R o/r issue create`.
- Full-suite evidence per X-B1 on #242: CI `Fixture tests` at the head sha; gitleaks `Exec format error` and `v0-gate.test.sh` timeout are host-only.
- Docs: `adapter-github.md` §Filing, `multi-account.md` worker row, `SKILL.md` step 7 and Files table.

## Next
- Review and merge the PR. Fleet-side label residue is X0.3.

## Notes
- `gh api` with a body flag (`-f`, `-F`, `--input`) and no `-X` is treated as POST, as gh does.
- `.claude/hooks/require-coordinator.js` is not installed (`.claude/**` is outside this lane); `scripts/test.sh` only requires it for the two worker hooks.

## Plan check

Package issue still matches: yes
