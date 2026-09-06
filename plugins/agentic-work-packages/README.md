# agentic-work-packages

Claude Code plugin bundling the Nodots agentic development workflow:

- **Skill** `agentic-work-packages` — decompose work into an issue hierarchy
  autonomous agents can execute in parallel: epics, path-scoped work packages
  ("cells"/"waves"), and blocking verification gates. Tracker-neutral core with
  GitHub Issues and Jira adapters.
- **Hooks** — two, both wired automatically on install.
  - `enforce-scope.js` (`PreToolUse` on `Edit|Write`) enforces the active work
    package's `SCOPE.json` path lanes. An out-of-lane write is denied with the
    blocker instruction, never a permission ask.
  - `require-handoff.js` (`Stop`) blocks a turn from ending on a dirty feature
    branch with neither `HANDOFF.md` nor `BLOCKER.md` written.

  Both fail open and say so on stderr: a repo with no `SCOPE.json` and a
  session on the default branch are unaffected, so enabling the plugin
  globally is safe.
- **Scripts** — `sync-cells.sh` derives each package's `cell:*` label from
  observable state (merged PRs, current evidence stamps, blockers on branches)
  rather than trusting a hand-set one; `aei-epic.js` optionally enumerates an
  epic's backlog for an external stop guard.
- **Worker contract** — `assets/worker-contract.md`, the checked-in contract a
  worker runs under, installed as `.claude/worker-contract.md` and imported
  from the repo's own `CLAUDE.md`.

The model was proven on a multi-phase program in `nodots/backgammon`
(~30 packages, five phases, four concurrent agents).

## Install

```bash
claude plugin marketplace add nodots/nodots-orchestrator
claude plugin install agentic-work-packages@nodots-plugins
```

The marketplace manifest lives at the root of `nodots/nodots-orchestrator`
(`.claude-plugin/marketplace.json`); this plugin is one entry in it. Private
repo: your git credentials must have access to the `nodots` org
(`gh auth setup-git` if marketplace updates fail in the background).

## Layout

```
.claude-plugin/plugin.json       plugin manifest
skills/agentic-work-packages/    the skill (SKILL.md + references + assets)
  references/                    epic, cell, gate, SCOPE.json, coordination, adapters
  assets/hooks/                  manual-install copies of both hooks
  assets/scripts/                bootstrap-github-labels.sh, sync-cells.sh, aei-epic.js
  assets/tests/                  fixture tests for the hooks and scripts
  assets/worker-contract.md      the checked-in worker contract
hooks/hooks.json                 wires both hooks
hooks/enforce-scope.js           SCOPE.json path-lane enforcement (PreToolUse)
hooks/require-handoff.js         written state before a turn ends (Stop)
```

The copies under `skills/.../assets/hooks/` are kept for manual (non-plugin)
installs into a repo's `.claude/settings.json`; the plugin wires both hooks
automatically via `hooks/hooks.json`. CI asserts the two copies of each hook
stay byte-identical.

## Tests

```bash
for t in plugins/agentic-work-packages/skills/agentic-work-packages/assets/tests/*.test.sh; do
  bash "$t"
done
```

Bash and Node builtins only, no dependencies. They run on every pull request.
