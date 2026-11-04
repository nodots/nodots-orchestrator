# HANDOFF: S0.5 — this repository publishes its own manifest

Run by the coordinator, not the fleet (epic #117 decisions log): every path in the lane is under `.claude/`.

## Done

- `.claude/standards.json`: one check, `test` → `bash scripts/test.sh`. Rules: `CLAUDE.md#rules` (check `test`), `CLAUDE.md#where-intent-and-spec-live` and `REVIEW.md` (check `null`). Preamble `.claude/standards-preamble.md`. No plugins.
- `.claude/standards-preamble.md`: seven lines, each restating `CLAUDE.md`.
- `.claude/hooks/standards-preamble.js`: copy of `assets/hooks/standards-preamble.js`, byte-identical; wired under `SessionStart` in `.claude/settings.json`, other entries unchanged.

## Proof

- Before the change: `node plugins/agentic-work-packages/skills/agentic-work-packages/assets/scripts/check-standards.js --root . .claude/standards.json` exited 2, `file not found`.
- After: exit 0, with exactly the two `rule has no check` warnings the package expects.
- Both fragments resolve to headings in `CLAUDE.md` (`## Rules`, `## Where intent and spec live`).
- The hook, run with `CLAUDE_PROJECT_DIR` at the worktree, prints the heading, `- test: bash scripts/test.sh`, and the preamble.

## Next

- SV0 (#123) asserts this manifest validates and its fragments resolve.
- Once an installed plugin version registers `standards-preamble.js` itself (`hooks/hooks.json`, from S0.2), a session here runs it twice: once from the plugin, once from `.claude/settings.json`. The preamble prints twice; nothing breaks. Drop one when the plugin version is bumped.

## Plan check

Package issue still matches: yes
