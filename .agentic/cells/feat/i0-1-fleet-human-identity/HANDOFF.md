# HANDOFF: I0.1 — fleet commits under the target clone's human identity

## Done

- `plugins/fleet/src/launch.js`: `readIdentity(git, localPath)` reads
  `git -C <localPath> config user.name` / `user.email`. Either one empty is
  refused `identity-missing`; the error names the clone and both `git config`
  commands. A `git config` exit other than 0 or 1 (1 = unset) is refused
  `identity-unreadable` and does not count as empty.
- `launch()` checks it right after the trust check, before CI and standards,
  so the dry run reports it and no worktree, branch or worker is made.
- `prepareWorktree` commits the scope and the re-cut through `commitAs(identity)`:
  `-c user.name/-c user.email` plus `GIT_AUTHOR_*`/`GIT_COMMITTER_*` in the env,
  so an inherited `GIT_*` variable cannot override the clone's identity. It
  reads the identity itself when no caller passes one.
- `plugins/fleet/bin/fleet.js` doctor: one `commit identity for <repo>` line per
  target, `ok` with `Name <email>`, or `FAIL` with the same error launch gives.
- README.md and skills/fleet/SKILL.md say whose identity fleet commits under,
  and SKILL.md lists the `launch-identity-missing` alarm.
- `plugins/fleet/tests/commit-identity.test.sh` (28 checks). It cuts off the global
  and system git config (`GIT_CONFIG_GLOBAL=/dev/null`, `GIT_CONFIG_NOSYSTEM=1`),
  so the machine's identity cannot stand in for the clone's. It failed 21 of 28
  checks against the pre-change tree, and they all pass now.
- `tests/lib.sh` was not changed: every existing fixture clone already sets a
  local `user.name`/`user.email`.

## Next

PR review and merge. Nothing is pending in this lane.

## Plan check

Package issue still matches: yes

`identity-unreadable` is the one thing added that the issue does not name. It
covers a `git config` that fails outright, which should not be reported as
"empty".
