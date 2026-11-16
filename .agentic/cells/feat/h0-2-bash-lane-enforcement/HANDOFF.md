# HANDOFF: H0.2 — lane enforcement for writes made through Bash

## Done

- `plugins/agentic-work-packages/hooks/enforce-scope.js` gains a PostToolUse
  `Bash` mode (`afterBash`). After each Bash call it lists the paths the branch
  changes with `git status --porcelain -z --untracked-files=all --no-renames`
  plus `git diff --name-only -z --no-renames <merge-base> HEAD`, judges them
  with the Edit/Write matcher, and returns `{"decision":"block"}` naming each
  out-of-lane path, telling the worker to revert or stop and write BLOCKER.md.
- `require-handoff.js` runs the same lane check at Stop and TaskCompleted,
  before the dirty-tree test, so a committed out-of-lane change on a clean
  tree blocks too. A BLOCKER.md does not excuse it. A lane it cannot evaluate
  is reported on stderr and skipped; the handoff check still runs.
- The lane matcher sits between `// --- lane matcher: begin` and
  `// --- lane matcher: end` in both hooks, byte-identical;
  `enforce-scope.test.sh` compares the two regions.
- The merge base is taken against the nearest integration branch (fewest
  commits ahead) among `origin/HEAD` and `development`, `develop`, `main`,
  `master`, local or on origin. Why nearest: this repo has both `main` and
  `development`, and packages merge into `development`; measuring from a
  default that lags it would count every merged package as this branch's
  change. Tested with a stale `main` and with a
  merge of `development` into the branch.
- `hooks/hooks.json` wires PostToolUse `Bash`. Asset copies mirrored.
- Both Residue headers and `references/scope-contract.md` updated.
- Tests first: commit c50596a holds the failing tests (15 and 11 failures
  against the old hooks); the next commit makes them pass.

## Next (outside this lane, for the coordinator)

- `assets/settings-snippet.json` (manual install) does not wire PostToolUse
  `Bash` yet; `scope-contract.md` tells installers to add it by hand.
- `references/adapter-github.md:182` still states the old Residue row.
- `.claude/worker-contract.md:21` and `assets/worker-contract.md:21` still say
  the hook judges Edit and Write only and shell writes are not intercepted.
- Installed copies in other repos get updated by PRs to those repos.

## Cold start

`bash plugins/agentic-work-packages/skills/agentic-work-packages/assets/tests/enforce-scope.test.sh`
and `.../require-handoff.test.sh` cover every case; `bash scripts/test.sh`
runs all of CI.

## Plan check

Package issue still matches: yes
