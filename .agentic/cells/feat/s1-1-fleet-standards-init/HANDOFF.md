# HANDOFF: S1.1 — `fleet standards init` drafts a target's manifest

## Done
- `plugins/fleet/tests/standards-init.test.sh`: committed first (35e3819), failing against the tree without the command.
- `plugins/fleet/src/standards.js`: `draftManifest(localPath)` → `{ manifest, notes }`; checks from `package.json` scripts `lint`, `typecheck`, `build`, `test` in that order (`plugins/fleet/src/standards.js:17-22`), rules from root `CLAUDE.md`, `CONTRIBUTING.md`, `AGENTS.md` (`plugins/fleet/src/standards.js:26`).
- `plugins/fleet/bin/fleet.js`: `fleet standards init --target <owner/repo> [--write]`, validated with `check-standards.js`.
- `plugins/fleet/README.md:154`: `## Standards` section, with no `npm run` / `npm test` literals (decision S1.1-text).
- Coordinator merged `origin/development` (c5cd7dc, decision S1.1-merge); the earlier BLOCKER.md was removed in 832ecf5.
- `bash scripts/test.sh` ends `ALL PASS` on this branch; `standards-init.test.sh` reports 31 checks, 0 failed.

## Next
- Review and merge the `[READY]: S1.1` PR against `development`.

## Plan check

Package issue still matches: yes
