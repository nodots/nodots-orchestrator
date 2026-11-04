# HANDOFF: S0.2 — SessionStart hook prints the repo's standards preamble

## Done

- `plugins/agentic-work-packages/skills/agentic-work-packages/assets/tests/standards-preamble.test.sh`
  committed first (59868ab). Against the pre-change tree it ran 44 checks, 34 failed
  (both hook files missing).
- `plugins/agentic-work-packages/hooks/standards-preamble.js` and its byte-identical asset
  copy. Root is `$CLAUDE_PROJECT_DIR`, else the cwd. No `.claude/standards.json`: silent,
  exit 0. With a manifest: the heading, `- <name>: <command>` per check, then a blank line
  and the `preamble` file verbatim. An unparsable manifest, a missing preamble file or any
  other error prints one stderr line prefixed `standards-preamble:`, nothing on stdout,
  exit 0. Output is buffered, so a late failure never leaves partial stdout. The manifest
  is not validated beyond parsing; a non-array `checks` prints no check lines.
- `hooks.json` registers it under `SessionStart` with `"matcher": ""`;
  `settings-snippet.json` wires `$CLAUDE_PROJECT_DIR/.claude/hooks/standards-preamble.js`.
- The test covers both copies: no manifest, manifest with preamble (exact output, in order),
  cwd fallback, no `preamble` key, missing preamble file, unparsable JSON. 44 checks, 0 failed.

## Next

- Coordinator review of the `[READY]: S0.2` PR. S0.5 (this repo's own manifest) depends on it.

## Cold-start notes

- `scripts/test.sh` takes more than 10 minutes here; most of that time is the eval stage.

## Plan check

Package issue still matches: yes
