# HANDOFF: X0.2 require-coordinator hook

## Done
- `plugins/agentic-work-packages/hooks/require-coordinator.js` and its byte-identical asset copy: with `FLEET_WORKER_ID` set, refuses `gh issue create`/`new`, coordinator-label writes (`gh issue edit`, `gh api`), `gh issue edit` body/title flags, and `gh api` issue creation and body/title edits. Fail open and loud.
- Wired in `hooks/hooks.json` and `assets/settings-snippet.json` (PreToolUse, Bash).
- `assets/tests/require-coordinator.test.sh` (213 checks).
- Attempt 2 review: `gh issue new` alias fixed.
- Attempt 3 review (coordinator, PR #256 at e815850), findings 1-8. Tests added first: 62 of 211 checks failed against e815850, covering every finding; all pass after the fix.
  1. Command word found past keywords (`do`, `then`, `{`, `!` ...), assignments and wrappers (`timeout`, `xargs`, `sudo` ...); `sh -c` strings, `eval` and heredocs fed to a shell are judged recursively.
  2. Backslash-newline is a line join, quoted or not.
  3. Label match is case-insensitive.
  4. `gh api -flabels[]=...` / `-Fkey=...` attached short flags read.
  5. `gh api` POST to `repos/o/r/issues`, and writes to `repos/o/r/issues/<n>` with a body/title field or `--input`, refused.
  6. `$(...)` and backticks inside double quotes open their own segment.
  7. Heredoc bodies are skipped unless fed to a shell; `#` comments skipped.
  8. gh's subcommand is its first positional word past `-R/--repo`, so flag values are never read as `issue` or `api`; the api endpoint is its first positional.
- Residue header updated: gh aliases, runtime-built commands, `cat f | bash`, `<<` inside `$(( ))`, full-URL endpoints, and the loose wrapper scan (false refusal, not a miss).
- Full-suite evidence per X-B1 on #242: CI `Fixture tests` at the head sha.

## Next
- Review and merge the PR. Fleet-side label residue is X0.3.

## Notes
- `gh api` with a body flag (`-f`, `-F`, `--input`) and no `-X` is treated as POST, as gh does.
- `.claude/hooks/require-coordinator.js` is not installed (`.claude/**` is outside this lane); `scripts/test.sh` only requires it for the two worker hooks.

## Plan check

Package issue still matches: yes
