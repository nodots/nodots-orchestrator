# Release notes

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
