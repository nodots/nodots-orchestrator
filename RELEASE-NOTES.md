# Release notes

## agentic-work-packages 1.7.1, fleet 0.5.1 (2026-11-17)

Fixes since 1.7.0 / 0.5.0:

- **A worker cut from an integration branch is no longer blocked at Stop** (#215, #217). The scope hooks took the merge base from `origin/HEAD` and `development`, `develop`, `main`, `master` only, so every package already merged into the integration branch counted as the worker's change. `SCOPE.json` takes an optional `baseBranch`; the hooks measure the lane from it (Stop, `TaskCompleted` and the Bash check), and fall back to the old rule without it. Fleet writes `baseBranch: <integrationBranch>` into the committed `SCOPE.json` and refuses an issue block that names a different one (`scope-base-mismatch`). `require-handoff` does not require a HANDOFF on a branch a `SCOPE.json` names as its `baseBranch`.
- **Fleet holds every re-dispatch of a package without `agent-ready`** (#218). Unpark, verify or review failure, escalation and relaunch now wait until the label is back, and the report lists them under **Held**. To finish a package by hand, remove `agent-ready` first.

### Upgrade notes

- **A package run by hand against an integration branch** sets `"baseBranch": "<integration branch>"` in its `SCOPE.json`. Fleet sets it for you.
- **Installed hook copies** (`.claude/hooks/enforce-scope.js`, `require-handoff.js`) in a target repository need the 1.7.1 versions. Copy them from the plugin's `hooks/`.

## agentic-work-packages 1.7.0, fleet 0.5.0 (2026-11-17)

Programs R, C, H and I, each closed by its gate: RV (#210), CV (#212), HV (#211), IV (#209). Platform support is unchanged from 1.6.0: `fleet` runs on macOS and Linux only.

### What is in this release

Since agentic-work-packages 1.6.0 and fleet 0.4.0:

- **Independent review (program R).** `review: { passes: N }` in `.claude/standards.json` asks for N `REVIEWED` stamps from distinct reviewers at a PR's head. A verified PR short of the policy is `cell:awaiting-reviewer` (#194). The fleet review stage launches a read-only reviewer from `reviewers` in the fleet config, stamps the PR or re-dispatches the package. Fleet names no vendor (#202). The CI stamp check reads the policy from the base branch and requires the stamps (#199).
- **Two-level merge (program C).** `targets[].integrationBranch`: workers branch from it and open PRs against it (#195). With `targets[].autoMerge: true`, fleet merges a PR into the integration branch when it is stamped, reviewed, green and mergeable, with a merge commit at the checked head. Fleet never merges into `main`, `master`, `develop`, `development`, the target's `defaultBranch` or a name in `protectedBranches`, and config validation refuses an `integrationBranch` on that list (#207). A PR merged into an integration branch is `cell:merged` and its dependents promote (#200). A person merges the integration branch into `develop`/`development` and `main`.
- **Hardening (program H).**
  - CI runs a pinned gitleaks over every commit a PR adds (`scripts/check-secrets.sh`, #205).
  - The scope hook enforces the lane for writes made through Bash (#197).
  - No interpreter wildcards in the allow rules; `fleet doctor` reports broad allow rules (#206).
  - The fleet fixture suites wait for the stub's files instead of reading them right after launch (#196, #201).
  - `scripts/test.sh` checks the installed hooks and the contract, as CI does (#208).
- **Human commit identity (program I).** Fleet commits under the target clone's human identity, not `fleet` (#188). Commits carry `Agent-Assisted: yes` in place of an AI co-author trailer, and CI refuses a commit with an AI author, committer or co-author trailer (`scripts/check-commit-identity.sh`, #204).

### Upgrade notes

- **A fleet target clone needs a git identity.** Launch refuses with `launch-identity-missing` when the clone has no `user.name` and `user.email`.
- **Projects that use the CI checks** need `.claude/settings.json` with `"attribution": {"commit": "Agent-Assisted: yes"}`, or Claude Code adds a `Co-Authored-By` trailer that `check-commit-identity.sh` refuses.
- **All keys are opt-in.** A target without `integrationBranch`, `autoMerge` or `reviewers`, and a manifest without `review`, behave as in 0.4.0.

### Known issues

- **The stamp check does not re-run when the stamp comment is posted.** A `[READY]` PR whose check ran before its stamp stays red until the check is re-run (`gh run rerun`).
- **Fleet does not re-dispatch a PR whose CI is red.** The coordinator handles it.
- **A coordinator who finishes a package by hand** must remove `agent-ready` first, or the daemon relaunches a worker into the same worktree.
- **#205, #206 and #207 carry `Co-Authored-By` trailers** in `development` history. Their branches were cut before #204 landed. The check runs over a PR's own commits, so it does not flag them.
- **One worker was denied `git add` and `git commit`** while both were on its allow list (HV, #187). The cause is not known.
- **Windows hosts** for `fleet` (#148).
- **The secret scan runs in CI on Linux. Run locally, it works only on Linux x64.** `scripts/check-secrets.sh` pins the `linux_x64` gitleaks archive. On macOS and Windows it refuses, or the binary does not execute, so `bash scripts/test.sh` ends `FAILED` there (`check-secrets`, `gate-h-hardening`, `v0-gate`). Neither plugin ships or calls the scanner; this affects contributors to this repository, not plugin users.

## agentic-work-packages 1.6.0, fleet 0.4.0 — preview (2026-11-16)

This is a preview. The code is new, and parts of it have not been verified on a real machine. Report problems as issues on `nodots/nodots-orchestrator` with the label `feedback:edi`.

### Supported platforms

| Component | macOS | Linux | Windows |
|---|---|---|---|
| `agentic-work-packages` skill (epics, packages, `SCOPE.json`) | yes | yes | yes, not tested |
| Hooks: `enforce-scope.js`, `require-handoff.js`, `standards-preamble.js` | yes | yes | yes, not tested |
| Scripts: `check-standards.js`, `stamp.js` | yes | yes | yes, not tested |
| `fleet` runtime (`fleet cycle`, `fleet daemon`) | yes | yes | **no** |

`fleet` runs only on macOS and Linux. It calls `bash` for `sync-cells.sh` and `assign-cells.sh`, reads process start times with `ps -o lstart=` (`src/exec.js`), and signals process groups with `process.kill(-pid)`. None of these work on Windows. On Windows, work packages by hand in Claude Code; a coordinator on macOS or Linux runs the fleet.

### What is in this release

Since agentic-work-packages 1.5.0 and fleet 0.3.0:

- **Standards manifest (program S).** A repository declares its check commands and rules in `.claude/standards.json` (#132). A SessionStart hook prints the repository's preamble (#131). The worker contract and the cell-worker agent read the manifest (#133). `fleet standards init` drafts a manifest (#144). Launch requires a valid manifest and gives the worker its checks and lane rules (#149). The eval runner's `lint` check runs the manifest (#136). Gates: SV0 (#135), SV1 (#150).
- **Operator isolation (program S, S2.1).** Workers run with `--setting-sources project,local` (`isolateWorkers`, default on). Launch refuses with `hooks-missing` or `plugin-missing` when the target's `.claude/settings.json` does not provide the worker hooks or a plugin the manifest declares (#168).
- **Instruction-file guard (program S, S2.2).** With `isolateWorkers` on, launch refuses with `instructions-leak` when an ancestor of the worktree holds `CLAUDE.md`, `CLAUDE.local.md` or `.claude/CLAUDE.md`. Claude Code loads those files from each ancestor of the working directory, so a worktree under the home directory would read the operator's `~/.claude/CLAUDE.md` as a project file (SV2 run 1, #129). The dry run and `fleet doctor` report the same check on `worktreesDir` (#170).
- **Verify queue (program K).** `targets[].verify` and `[VERIFY]` PRs (#106), `cell:awaiting-lab` (#104), the verify stage: one run in flight, stamp or re-dispatch (#112), `verify.kind: manual` (#115).
- **fleet daemon.** Cycles on an interval and on worker exit, for several programs (#111).
- **Fleet fixes.** A cycle acts only on its epic's packages (#110, #95). Adoption commits and pushes the lane (#109). A worker that dies without an exit file is an alarm (#114). `sync-cells` matches a PR title by the bounded package ID (#142).
- **Hooks.** `require-handoff` exempts `develop` (#151).
- **Docs.** Developer guide (#167) and coordinator cheat sheet (#152).

### Known issues

- **`worktreesDir` must be outside the home directory** when `isolateWorkers` is on. A fleet config with `worktreesDir` under the home directory is now refused with `instructions-leak` (S2.2, #170). Move it, for example to `/srv/fleet-worktrees` on Linux or `/Users/Shared/fleet-worktrees` on macOS.
- **SV2 (#129) has not passed.** The scope hook under `--setting-sources project,local` has not been verified on a real machine.
- **A target needs its own `.claude/settings.json`.** Under isolation, allow rules and plugins from user settings do not apply. Without project allow rules for `gh` and `git`, a worker cannot read its issue, commit or open a PR, and parks with a `BLOCKER.md`.
- **Four fleet fixture suites fail on macOS** (`adoption`, `standards-isolation`, `standards-launch`, `sv1-standards-gate`). Each failing assertion reads the claude stub's argv file right after the detached launch. CI on Linux passes.

### Install (Windows)

1. Install Git for Windows, Node.js 22, the GitHub CLI and Claude Code.
2. `gh auth login`, then `claude auth login`.
3. In Claude Code:
   ```
   /plugin marketplace add nodots/nodots-orchestrator
   /plugin install agentic-work-packages@nodots-plugins
   ```
4. Read `docs/developer-guide.md` and the cheat sheet at `plugins/agentic-work-packages/skills/agentic-work-packages/references/cheat-sheet.md`.

Updates arrive only when the plugin version changes. Merges to `development` without a version bump do not reach installed copies.
