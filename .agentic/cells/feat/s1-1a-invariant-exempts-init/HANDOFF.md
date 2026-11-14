# HANDOFF: S1.1a — the text invariant exempts the file that drafts a target's commands

## Done

- `plugins/agentic-work-packages/skills/agentic-work-packages/assets/tests/sv0-standards-gate.test.sh`, §4:
  - The pattern and pathspecs of the text-invariant `git grep` are now `TEXT_PATTERN` and
    `TEXT_PATHSPECS`, so the main grep and the new case run the same grep.
  - `TEXT_PATHSPECS` gains `':!plugins/fleet/src/standards.js'`, with a one-line comment
    citing decision S1.1-text on #117. No other file or directory is exempted.
  - New case `text/exempt`: a temp git repo commits `plugins/fleet/README.md` and
    `plugins/fleet/src/standards.js`, each containing `npm run lint`. The same grep, run
    with `-C` on that repo, must exit 0 and print exactly
    `plugins/fleet/README.md:1:npm run lint`.
- Commit order: `7da0eb1` adds the case and fails (the grep also names `standards.js`);
  `5435d32` adds the exemption and the gate passes, 71 checks, 0 failed.
- The real repo has no `plugins/fleet/src/standards.js` yet; the main grep still exits 1
  with the exclusion pathspec present.

## Deviation from the package text

The case also commits `plugins/fleet/src/standards.js` to the temp repo. Without it, the
case passes against the pre-change gate, so it could not fail first, as the worker
contract (§4) requires. With it, the case proves both halves: the README still fails the
grep, and the exempt file does not.

## Next

Merge, then S1.1 (#124) is unblocked.

## Plan check

Package issue still matches: yes
