# BLOCKER: S1.2 — the worker session cannot run `git merge origin/development`

**Bucket:** on a missing capability
**Kind:** human-decision
**Reference:** issue #125 (the "On relaunch" note, decision S1.2-D1 on #117); `.claude/settings.json` `permissions.allow`
**Owner:** coordinator
**Un-blocks when:** `origin/development` (at or after 3157f7e, the #140 merge) is an ancestor of `origin/feat/s1-2-launch-requires-manifest`

## What was needed, and why

Issue #125 says to merge `origin/development` into this branch first, because
S1.2a (#140) gives the ten launching fleet suites a manifest through
`fixture_standards` in `plugins/fleet/tests/lib.sh`. This session runs with no
approval surface. `git merge` and `git fetch` are not in
`.claude/settings.json` `permissions.allow` (`git status|diff|log|add|commit|push`
are), so both were denied automatically. `origin/development` was already
fetched into the clone at 3157f7e.

The package work is done and committed on top of the unmerged branch (see
HANDOFF.md). `bash scripts/test.sh` on that tree fails, deterministically, in
exactly the ten suites #140 changed (adoption, ci-preconditions, cycle, daemon,
epic-scope, v4-gate, vanished, verify-config, verify-manual, verify-stage; plus
v0-gate, which runs test.sh on a clean copy). Each failure is a launch that
does not happen, for example `ci-preconditions.test.sh` "A: a default-tier
package launches", `[] does not contain [10]`: the fixture has no manifest, so
launch now refuses it `standards-missing`. That is the intended behavior.

`git diff --stat HEAD...origin/development` touches no file this package
changed, so the merge should be conflict-free.

## Alternatives searched
- `git merge` with and without the `cd` prefix — denied both times (not in the allow list).
- Running git through `node -e` (`node:*` is allowed) — not done: it would get
  around a permission the operator withheld, which is the same failure as
  writing outside the lane through a shell redirect.
- Adding `fixture_standards` calls to the ten suites myself — they are outside
  `allowedPaths`, and #140 already did it on development.
- Opening the PR without the merge — `bash scripts/test.sh` does not end
  `ALL PASS`, so no `[READY]` PR and no VERIFIED stamp is possible.

## The ask
S1.2-B2: merge `origin/development` into `feat/s1-2-launch-requires-manifest`
and push (option a), or add `Bash(git merge:*)` and `Bash(git fetch:*)` to the
allow list and relaunch (option b) : recommend (a), it is one command and needs
no settings change : decide-by the next cycle : cost-of-waiting S1.2's PR, and
anything in program S that depends on S1.2
