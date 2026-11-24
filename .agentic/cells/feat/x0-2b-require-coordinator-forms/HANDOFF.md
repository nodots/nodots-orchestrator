# HANDOFF: X0.2b (#260)

## Done
- `plugins/agentic-work-packages/hooks/require-coordinator.js` (asset copy byte-identical):
  - `commandIndex` skips `function NAME`, so a `function f { gh ...; }` body is judged.
  - `judgeFind`: each `-exec`/`-execdir`/`-ok`/`-okdir` command (to `;` or `+`) is judged as words.
  - `judgeParallel`: words before `:::`/`::::` are judged — each whitespace-bearing word as a command line, and the words from the first runner word, joined.
  - Here-strings fed to a shell are judged; the parser now ends the word before `<<<`, so `bash<<<"..."` and `0<<<` are caught.
  - `judgeApi`: the `labels` field check applies only to a write method; `-X GET ... -f labels=...` is allowed, a field with no `-X` is still a POST and refused.
  - Residue header lists what is still uncaught (parallel commands from args/files, redirect before the command word, nesting > 4) and the new false refusals.
- Tests: 20 refused and 8 allowed cases added to `assets/tests/require-coordinator.test.sh`, written before the change (25 red on the pre-change hook, plus 10 red for the review's parallel/here-string forms). 275 checks, 0 failed.
- Review (implement+review): an independent reviewer flagged quoted `parallel` command lines and glued here-strings; all confirmed by test, fixed.

## Next
- Coordinator review and merge of the `[READY]: X0.2b` PR.

## Plan check

Package issue still matches: yes
