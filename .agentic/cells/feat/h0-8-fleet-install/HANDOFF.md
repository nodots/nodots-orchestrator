# HANDOFF: H0.8 — fleet install, doctor drift

## Done

- `plugins/fleet/tests/install.test.sh` was written first. Against the
  pre-change tree it failed 42 of 59 checks.
- `plugins/fleet/src/install.js`:
  - `plan()` compares the three hooks, the worker contract and the
    `settings-snippet.json` registrations with `launch.baseRef(target)` in the
    clone.
  - `apply()` checks identity (refused `launch-identity-missing`), fetches,
    re-plans, and refuses a branch that already exists. It then cuts
    `chore/install-agentic-work-packages-<version>` in a worktree under
    `worktreesDir`, commits once, and does a plain push. After the push it
    removes the worktree and the local branch, so a later install starts clean.
  - `doctor()` writes the per-file and per-event checks.
- `plugins/fleet/bin/fleet.js`:
  - the `install` command;
  - a usage line, with `usage()`'s slice widened by one;
  - doctor now calls `install.doctor`. That replaces the presence-only hooks
    check and the clone-tree `worker contract installed` check, both covered by
    the base-ref comparison.
- `plugins/fleet/tests/cycle.test.sh` K: the assertion now names the new doctor
  line (`FAIL  worker file .claude/hooks/enforce-scope.js in acme/api`). It
  asserts the same thing, a target without committed hooks fails doctor. No
  other suite asserted on the replaced lines.
- Docs:
  - README "Installing the worker files", plus layout entries;
  - SKILL.md doctor paragraph, which names the command.

## Decisions a reviewer should know

- The version comes from `pluginRoot/.claude-plugin/plugin.json`.
- A registration is present when a group of the same event and matcher runs the
  same command. A missing one is appended to that group, or added as a new
  group.
- An absent `settings.json` is written as the snippet's bytes.
- A `settings.json` on the base ref that is not valid JSON is an error, never
  overwritten.
- `commitAs` is duplicated from `launch.js`, which is forbidden in this lane and
  does not export it.

## Next

- E0.3 (#222) adds its workflow and runner to `COPIES` in `install.js` when it
  lands.

## Plan check

Package issue still matches: yes
