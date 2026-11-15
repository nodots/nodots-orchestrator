# HANDOFF: S2.2 — launch refuses a worktree whose ancestors hold an instruction file

## Done

- `plugins/fleet/src/launch.js`: `instructionFilesFrom(dir)` walks `dir` and each
  ancestor to `/` for `CLAUDE.md`, `CLAUDE.local.md`, `.claude/CLAUDE.md`.
  `checkInstructionsLeak(worktree)` starts the walk at the worktree's parent and
  returns stage `instructions-leak`, naming each file and both fixes
  (`worktreesDir`, `isolateWorkers`). `launch()` runs it inside the
  `cfg.isolateWorkers` block after `checkIsolation`, before the dry-run return,
  so the dry run reports it and no worktree is created on refusal. The cycle
  raises it as alarm `launch-instructions-leak` (`src/cycle.js:231`).
- `plugins/fleet/bin/fleet.js`: `fleet doctor` runs `instructionFilesFrom` on
  `worktreesDir` with isolation on; with it off, the line is `ok` and says
  "not checked, isolateWorkers is false".
- `plugins/fleet/tests/instructions-leak.test.sh`: cases A–F (`.claude/CLAUDE.md`,
  `CLAUDE.md`, `CLAUDE.local.md`, two files, clean, `isolateWorkers: false`),
  dry run, applied cycle and doctor. Committed failing first (7b0990f: 20 of
  31 failed against the pre-change tree).
- `plugins/fleet/README.md`, `plugins/fleet/skills/fleet/SKILL.md`: the
  precondition and the `worktreesDir` requirement.

## Not done / notes

- The walk uses `path.resolve`, not `realpath`; a `worktreesDir` reached through
  a symlink is checked along the path as written.
- Host check: existing suites build under `mktemp -d` (`/tmp`), and no suite was
  refused `instructions-leak` on this host, so no BLOCKER was needed.
- Operator follow-up (out of scope, per the issue): move program S's
  `worktreesDir` and the SV2 fixture's out of `$HOME`; confirm trust of a linked
  worktree outside `$HOME` (`src/trust.js`).

## Plan check

Package issue still matches: yes
