# agentic-work-packages

Claude Code plugin bundling the Nodots agentic development workflow:

- **Skill** `agentic-work-packages` — decompose work into an issue hierarchy
  autonomous agents can execute in parallel: epics, path-scoped work packages
  ("cells"/"waves"), and blocking verification gates. Tracker-neutral core with
  GitHub Issues and Jira adapters.
- **Hook** — a `PreToolUse` hook on `Edit|Write` that enforces the active work
  package's `SCOPE.json` path lanes. Fails open: repos without a `SCOPE.json`
  are unaffected, so enabling the plugin globally is safe.

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
hooks/hooks.json                 wires the enforce-scope hook
hooks/enforce-scope.js           SCOPE.json path-lane enforcement
```

The copy under `skills/.../assets/hooks/` is kept for manual (non-plugin)
installs into a repo's `.claude/settings.json`; the plugin wires the hook
automatically via `hooks/hooks.json`.
